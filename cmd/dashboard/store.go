package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const defaultCacheSubdir = "Library/Caches/jp.kasutera.hubfred"

// dashboardStore owns the dashboard and picker SQLite snapshots. Its schema is
// shared with the legacy Alfred picker, so keep table and column names stable.
type dashboardStore struct {
	Dir, Path, PickerPath, Scope, GH string
	Limit, Days                     int
	Cutoff                          time.Time
	Fresh, Stale                    time.Duration
}

func newDashboardStore(uiDir, kind string) (dashboardStore, error) {
	var dashboardName, scopedName, pickerName string
	switch kind {
	case "prs":
		dashboardName, scopedName, pickerName = "dashboard-v3.sqlite3", "dashboard-scope-v1.sqlite3", "pr-picker-v2.sqlite3"
	case "issues":
		dashboardName, scopedName, pickerName = "issues-dashboard-v3.sqlite3", "issues-dashboard-scope-v1.sqlite3", "issue-picker-v2.sqlite3"
	case "all":
		dashboardName, scopedName, pickerName = "github-dashboard-v1.sqlite3", "github-dashboard-scope-v1.sqlite3", "github-picker-v2.sqlite3"
	default:
		return dashboardStore{}, fmt.Errorf("unknown dashboard kind %q", kind)
	}

	fresh, stale, err := cacheThresholds(uiDir)
	if err != nil {
		return dashboardStore{}, err
	}
	limit := normalizeDashboardSetting(os.Getenv("hubfred_dashboard_limit"), 100, 1, 1000)
	days := normalizeDashboardSetting(os.Getenv("hubfred_dashboard_days"), 0, 0, 36500)

	dir := os.Getenv("alfred_workflow_cache")
	if dir == "" {
		home := os.Getenv("HOME")
		if home == "" {
			var homeErr error
			home, homeErr = os.UserHomeDir()
			if homeErr != nil {
				return dashboardStore{}, fmt.Errorf("resolve home directory: %w", homeErr)
			}
		}
		dir = filepath.Join(home, filepath.FromSlash(defaultCacheSubdir))
	}
	if dir == "" {
		return dashboardStore{}, errors.New("cache directory is empty")
	}
	if info, statErr := os.Stat(dir); statErr == nil && !info.IsDir() {
		return dashboardStore{}, fmt.Errorf("cache path %q is not a directory", dir)
	} else if statErr != nil && !errors.Is(statErr, os.ErrNotExist) {
		return dashboardStore{}, fmt.Errorf("inspect cache directory %q: %w", dir, statErr)
	}

	store := dashboardStore{
		Dir:        dir,
		PickerPath: filepath.Join(dir, pickerName),
		Limit:      limit,
		Days:       days,
		Fresh:      fresh,
		Stale:      stale,
		GH:         resolveGH(),
	}
	if days > 0 {
		store.Cutoff = time.Now().UTC().Truncate(time.Second).Add(-time.Duration(days) * 24 * time.Hour)
	}
	if limit == 1000 && days == 0 {
		store.Path = filepath.Join(dir, dashboardName)
	} else {
		store.Path = filepath.Join(dir, scopedName)
		store.Scope = fmt.Sprintf("%d:%d", limit, days)
	}
	return store, nil
}

func cacheThresholds(uiDir string) (time.Duration, time.Duration, error) {
	if uiDir == "" {
		executable, err := os.Executable()
		if err != nil {
			return 0, 0, fmt.Errorf("locate dashboard UI directory: %w", err)
		}
		uiDir = filepath.Dir(executable)
	}
	file, err := os.Open(filepath.Join(uiDir, "cache-decisions.sh"))
	if err != nil {
		return 0, 0, fmt.Errorf("open cache decisions in %q: %w", uiDir, err)
	}
	defer file.Close()

	values := make(map[string]time.Duration, 2)
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(strings.SplitN(scanner.Text(), "#", 2)[0])
		fields := strings.Fields(line)
		if len(fields) != 2 || fields[0] != "readonly" {
			continue
		}
		name, literal, ok := strings.Cut(fields[1], "=")
		if !ok || (name != "CACHE_FRESH_SECONDS" && name != "CACHE_STALE_SECONDS") {
			continue
		}
		seconds, parseErr := strconv.ParseUint(literal, 10, 63)
		if parseErr != nil || seconds == 0 || seconds > uint64(math.MaxInt64/int64(time.Second)) {
			return 0, 0, fmt.Errorf("invalid %s literal in cache-decisions.sh", name)
		}
		if _, duplicate := values[name]; duplicate {
			return 0, 0, fmt.Errorf("duplicate %s definition in cache-decisions.sh", name)
		}
		values[name] = time.Duration(seconds) * time.Second
	}
	if err := scanner.Err(); err != nil {
		return 0, 0, fmt.Errorf("read cache decisions: %w", err)
	}
	fresh, hasFresh := values["CACHE_FRESH_SECONDS"]
	stale, hasStale := values["CACHE_STALE_SECONDS"]
	if !hasFresh || !hasStale || stale < fresh {
		return 0, 0, errors.New("cache-decisions.sh must define valid fresh and stale thresholds")
	}
	return fresh, stale, nil
}

func normalizeDashboardSetting(value string, fallback, minimum, maximum int) int {
	if value == "" {
		return fallback
	}
	for _, char := range value {
		if char < '0' || char > '9' {
			return fallback
		}
	}
	normalized := strings.TrimLeft(value, "0")
	if normalized == "" {
		normalized = "0"
	}
	maxLiteral := strconv.Itoa(maximum)
	if len(normalized) > len(maxLiteral) {
		return maximum
	}
	parsed, err := strconv.Atoi(normalized)
	if err != nil {
		return fallback
	}
	if parsed < minimum {
		return minimum
	}
	if parsed > maximum {
		return maximum
	}
	return parsed
}

func resolveGH() string {
	if resolved, err := exec.LookPath("gh"); err == nil {
		if absolute, absErr := filepath.Abs(resolved); absErr == nil {
			return absolute
		}
		return resolved
	}
	for _, candidate := range []string{"/opt/homebrew/bin/gh", "/usr/local/bin/gh"} {
		info, err := os.Stat(candidate)
		if err == nil && !info.IsDir() && info.Mode()&0111 != 0 {
			return candidate
		}
	}
	return ""
}

func (s dashboardStore) credential(ctx context.Context) (token, identity string, err error) {
	token = os.Getenv("GH_TOKEN")
	if token == "" {
		token = os.Getenv("GITHUB_TOKEN")
	}
	if token == "" && s.GH != "" {
		cmd := exec.CommandContext(ctx, s.GH, "auth", "token", "--hostname", "github.com")
		cmd.Env = environmentWith(os.Environ(), "GH_HOST", "github.com", "GH_PROMPT_DISABLED", "1", "GH_NO_UPDATE_NOTIFIER", "1")
		cmd.Stderr = io.Discard
		output, runErr := cmd.Output()
		if runErr != nil {
			if ctx.Err() != nil {
				return "", "", ctx.Err()
			}
			return "", "", nil
		}
		token = strings.TrimRight(string(output), "\r\n")
	}
	if token == "" {
		return "", "", nil
	}
	digest := sha256.Sum256([]byte("token\x00" + token))
	return token, fmt.Sprintf("%x  -", digest), nil
}

func environmentWith(environment []string, keysAndValues ...string) []string {
	result := make([]string, 0, len(environment)+len(keysAndValues)/2)
	for _, entry := range environment {
		key, _, _ := strings.Cut(entry, "=")
		replaced := false
		for i := 0; i < len(keysAndValues); i += 2 {
			if key == keysAndValues[i] {
				replaced = true
				break
			}
		}
		if !replaced {
			result = append(result, entry)
		}
	}
	for i := 0; i < len(keysAndValues); i += 2 {
		result = append(result, keysAndValues[i]+"="+keysAndValues[i+1])
	}
	return result
}

func (s dashboardStore) read(ctx context.Context, identity string, picker bool) ([]item, time.Duration, error) {
	path, table := s.Path, "dashboard"
	if picker {
		path, table = s.PickerPath, "picker"
	}
	if identity == "" {
		return nil, s.Stale, nil
	}
	if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
		return nil, s.Stale, nil
	} else if err != nil {
		return nil, s.Stale, fmt.Errorf("inspect cache %q: %w", path, err)
	}

	query := "SELECT unixepoch() - saved_at, list FROM " + table + " WHERE identity = " + sqlLiteral(identity)
	if !picker && s.Scope != "" {
		query += " AND scope = " + sqlLiteral(s.Scope)
	}
	output, err := sqlite(ctx, path, true, true, query)
	if err != nil {
		if isMissingCacheSchema(err) {
			return nil, s.Stale, nil
		}
		return nil, s.Stale, err
	}
	output = strings.TrimSuffix(output, "\n")
	if output == "" {
		return nil, s.Stale, nil
	}
	separator := strings.IndexByte(output, '\n')
	if separator < 0 {
		return nil, s.Stale, errors.New("malformed dashboard cache row")
	}
	seconds, err := strconv.ParseInt(output[:separator], 10, 64)
	if err != nil {
		return nil, s.Stale, fmt.Errorf("parse cache age: %w", err)
	}
	age := cacheAge(seconds)
	var snapshot struct {
		Items []item `json:"items"`
	}
	if err := json.Unmarshal([]byte(output[separator+1:]), &snapshot); err != nil {
		return nil, age, fmt.Errorf("decode dashboard cache list: %w", err)
	}
	return snapshot.Items, age, nil
}

func (s dashboardStore) save(ctx context.Context, identity string, items []item) error {
	if identity == "" {
		return errors.New("cannot save dashboard cache without an identity")
	}
	if err := os.MkdirAll(s.Dir, 0700); err != nil {
		return fmt.Errorf("create cache directory: %w", err)
	}
	file, err := os.CreateTemp(s.Dir, ".dashboard-*.sqlite3")
	if err != nil {
		return fmt.Errorf("create temporary dashboard cache: %w", err)
	}
	temporary := file.Name()
	cleanup := func() {
		_ = os.Remove(temporary)
		_ = os.Remove(temporary + "-journal")
		_ = os.Remove(temporary + "-wal")
		_ = os.Remove(temporary + "-shm")
	}
	defer cleanup()
	if err := file.Chmod(0600); err != nil {
		_ = file.Close()
		return fmt.Errorf("protect temporary dashboard cache: %w", err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("close temporary dashboard cache: %w", err)
	}

	listItems := append([]item(nil), items...)
	for index := range listItems {
		listItems[index].Body = nil
	}
	listJSON, err := json.Marshal(struct {
		Items []item `json:"items"`
	}{Items: listItems})
	if err != nil {
		return fmt.Errorf("encode dashboard cache list: %w", err)
	}
	digestJSON, err := json.Marshal(struct {
		Items []item `json:"items"`
	}{Items: items})
	if err != nil {
		return fmt.Errorf("encode dashboard cache digest: %w", err)
	}
	digest := fmt.Sprintf("%x  -", sha256.Sum256(digestJSON))

	scopeColumn, scopeValue := "", ""
	if s.Scope != "" {
		scopeColumn, scopeValue = ", scope TEXT NOT NULL", ", "+sqlLiteral(s.Scope)
	}
	var statement strings.Builder
	statement.Grow(len(listJSON) + len(identity) + len(digest) + len(items)*64)
	statement.WriteString("BEGIN IMMEDIATE;\n")
	statement.WriteString("CREATE TABLE dashboard (identity TEXT NOT NULL, saved_at INTEGER NOT NULL, digest TEXT NOT NULL, list TEXT NOT NULL")
	statement.WriteString(scopeColumn)
	statement.WriteString(");\nCREATE TABLE bodies (url TEXT PRIMARY KEY, body TEXT NOT NULL) WITHOUT ROWID;\n")
	statement.WriteString("INSERT INTO dashboard (identity, saved_at, digest, list")
	statement.WriteString(scopeColumnName(s.Scope))
	statement.WriteString(") VALUES (")
	statement.WriteString(sqlLiteral(identity))
	statement.WriteString(", unixepoch(), ")
	statement.WriteString(sqlLiteral(digest))
	statement.WriteString(", ")
	statement.WriteString(sqlLiteral(string(listJSON)))
	statement.WriteString(scopeValue)
	statement.WriteString(");\n")
	for _, value := range items {
		if value.Body == nil || value.UID == "" {
			continue
		}
		bodyJSON, marshalErr := json.Marshal(*value.Body)
		if marshalErr != nil {
			return fmt.Errorf("encode description for %q: %w", value.UID, marshalErr)
		}
		statement.WriteString("INSERT INTO bodies VALUES (")
		statement.WriteString(sqlLiteral(value.UID))
		statement.WriteString(", ")
		statement.WriteString(sqlLiteral(string(bodyJSON)))
		statement.WriteString(");\n")
	}
	statement.WriteString("COMMIT;\n")
	if _, err := sqlite(ctx, temporary, false, false, statement.String()); err != nil {
		return err
	}
	if err := os.Chmod(temporary, 0600); err != nil {
		return fmt.Errorf("protect dashboard cache: %w", err)
	}
	if err := os.Rename(temporary, s.Path); err != nil {
		return fmt.Errorf("publish dashboard cache: %w", err)
	}
	return nil
}

func scopeColumnName(scope string) string {
	if scope == "" {
		return ""
	}
	return ", scope"
}

func (s dashboardStore) body(ctx context.Context, identity, url string) (string, bool, error) {
	if identity == "" || url == "" {
		return "", false, nil
	}
	if _, err := os.Stat(s.Path); errors.Is(err, os.ErrNotExist) {
		return "", false, nil
	} else if err != nil {
		return "", false, fmt.Errorf("inspect cache %q: %w", s.Path, err)
	}
	query := "SELECT body FROM bodies WHERE url = " + sqlLiteral(url) + " AND EXISTS (SELECT 1 FROM dashboard WHERE identity = " + sqlLiteral(identity)
	if s.Scope != "" {
		query += " AND scope = " + sqlLiteral(s.Scope)
	}
	query += ");"
	output, err := sqlite(ctx, s.Path, true, false, query)
	if err != nil {
		if isMissingCacheSchema(err) {
			return "", false, nil
		}
		return "", false, err
	}
	output = strings.TrimSuffix(output, "\n")
	if output == "" {
		return "", false, nil
	}
	var body string
	if err := json.Unmarshal([]byte(output), &body); err != nil {
		return "", false, fmt.Errorf("decode cached description: %w", err)
	}
	return body, true, nil
}

func sqlite(ctx context.Context, path string, readOnly, separateColumns bool, query string) (string, error) {
	args := []string{"-batch", "-bail", "-init", "/dev/null"}
	if readOnly {
		args = append(args, "-readonly")
	}
	if separateColumns {
		args = append(args, "-separator", "\n")
	}
	args = append(args, path)
	cmd := exec.CommandContext(ctx, "/usr/bin/sqlite3", args...)
	cmd.Stdin = strings.NewReader(query)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	output, err := cmd.Output()
	if err != nil {
		if ctx.Err() != nil {
			return "", ctx.Err()
		}
		return "", fmt.Errorf("sqlite3 %q: %w: %s", path, err, strings.TrimSpace(stderr.String()))
	}
	return string(output), nil
}

func sqlLiteral(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "''") + "'"
}

func isMissingCacheSchema(err error) bool {
	message := err.Error()
	return strings.Contains(message, "no such table") || strings.Contains(message, "no such column")
}

func cacheAge(seconds int64) time.Duration {
	maximum := int64(math.MaxInt64 / int64(time.Second))
	minimum := int64(math.MinInt64 / int64(time.Second))
	if seconds > maximum {
		return time.Duration(math.MaxInt64)
	}
	if seconds < minimum {
		return time.Duration(math.MinInt64)
	}
	return time.Duration(seconds) * time.Second
}
