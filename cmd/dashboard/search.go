package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/textproto"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const maxSearchResults = 1000

var iconColors = [...]string{"AC6B49", "4269A5", "A48332", "B15F91", "4E94B8", "62636D"}

type searchCategory struct {
	kind      string
	qualifier string
	reason    string
}

type searchUser struct {
	Login string `json:"login"`
}

type searchLabel struct {
	Name string `json:"name"`
}

type searchAPIItem struct {
	HTMLURL       string        `json:"html_url"`
	UpdatedAt     time.Time     `json:"updated_at"`
	RepositoryURL string        `json:"repository_url"`
	User          searchUser    `json:"user"`
	Draft         bool          `json:"draft"`
	Number        int           `json:"number"`
	Title         string        `json:"title"`
	Body          string        `json:"body"`
	Labels        []searchLabel `json:"labels"`
}

type searchAPIResponse struct {
	TotalCount int             `json:"total_count"`
	Incomplete bool            `json:"incomplete_results"`
	Items      []searchAPIItem `json:"items"`
}

type searchReceipt struct {
	Kind       string          `json:"kind"`
	Category   string          `json:"category"`
	Query      string          `json:"query"`
	PerPage    int             `json:"perPage"`
	Loaded     int             `json:"loaded"`
	TotalCount int             `json:"totalCount"`
	NextPage   int             `json:"nextPage"`
	Items      []searchAPIItem `json:"items"`
}

func searchFirst(ctx context.Context, ghPath, token, workflowDir, cacheDir, kind, session string, limit int, cutoff time.Time) ([]item, bool, error) {
	categories, err := searchCategories(kind)
	if err != nil {
		return nil, false, err
	}
	limit, err = normalizedSearchLimit(limit)
	if err != nil {
		return nil, false, err
	}
	if err := validateSearchPaths(workflowDir, cacheDir, session); err != nil {
		return nil, false, err
	}

	loginBytes, err := runGH(ctx, ghPath, token, "api", "user", "--jq", ".login")
	if err != nil {
		return nil, false, fmt.Errorf("looking up GitHub login: %w", err)
	}
	login := strings.TrimSpace(string(loginBytes))
	if login == "" {
		return nil, false, errors.New("GitHub returned an empty login")
	}

	perPage := limit
	if perPage > 100 {
		perPage = 100
	}
	queries := make([]string, len(categories))
	for i, category := range categories {
		queryKind := "issue"
		if category.kind == "prs" {
			queryKind = "pr"
		}
		queries[i] = "is:" + queryKind + " is:open " + category.qualifier + ":" + login
		if !cutoff.IsZero() {
			queries[i] += " updated:>=" + cutoff.UTC().Format(time.RFC3339)
		}
	}

	receipts := make([]searchReceipt, len(categories))
	pacer := &searchPacer{}
	if err := runCategoryTasks(ctx, len(categories), func(taskCtx context.Context, i int) error {
		receipt, err := searchFirstCategory(taskCtx, ghPath, token, session, i, kind, categories[i], queries[i], perPage, limit, pacer)
		if err == nil {
			receipts[i] = receipt
		}
		return err
	}); err != nil {
		return nil, false, err
	}

	items, err := formatSearchItems(receipts, categories, kind, workflowDir, cacheDir)
	if err != nil {
		return nil, false, err
	}
	more := false
	for _, receipt := range receipts {
		if receipt.NextPage > 0 {
			more = true
			break
		}
	}
	return items, more, nil
}

func searchMore(ctx context.Context, ghPath, token, workflowDir, cacheDir, kind, session string, limit int) ([]item, error) {
	categories, err := searchCategories(kind)
	if err != nil {
		return nil, err
	}
	limit, err = normalizedSearchLimit(limit)
	if err != nil {
		return nil, err
	}
	if err := validateSearchPaths(workflowDir, cacheDir, session); err != nil {
		return nil, err
	}

	receipts := make([]searchReceipt, len(categories))
	for i, category := range categories {
		path := searchReceiptPath(session, i)
		if err := readSearchReceipt(path, &receipts[i]); err != nil {
			return nil, fmt.Errorf("reading pending search category %d: %w", i, err)
		}
		if receipts[i].Kind != kind || receipts[i].Category != categoryKey(category) || receipts[i].Query == "" {
			return nil, fmt.Errorf("pending search category %d does not match %s", i, kind)
		}
	}

	pacer := &searchPacer{}
	if err := runCategoryTasks(ctx, len(categories), func(taskCtx context.Context, i int) error {
		receipt := &receipts[i]
		return searchMoreCategory(taskCtx, ghPath, token, receipt, limit, pacer)
	}); err != nil {
		return nil, err
	}
	return formatSearchItems(receipts, categories, kind, workflowDir, cacheDir)
}

func searchCategories(kind string) ([]searchCategory, error) {
	prs := []searchCategory{
		{kind: "prs", qualifier: "author", reason: "Authored"},
		{kind: "prs", qualifier: "user-review-requested", reason: "Review requested"},
	}
	issues := []searchCategory{
		{kind: "issues", qualifier: "assignee", reason: "Assigned"},
		{kind: "issues", qualifier: "author", reason: "Authored"},
		{kind: "issues", qualifier: "mentions", reason: "Mentioned"},
		{kind: "issues", qualifier: "commenter", reason: "Commented"},
	}
	switch kind {
	case "prs":
		return prs, nil
	case "issues":
		return issues, nil
	case "all":
		return append(prs, issues...), nil
	default:
		return nil, fmt.Errorf("invalid search kind %q", kind)
	}
}

func normalizedSearchLimit(limit int) (int, error) {
	if limit < 1 {
		return 0, errors.New("search limit must be positive")
	}
	if limit > maxSearchResults {
		return maxSearchResults, nil
	}
	return limit, nil
}

func validateSearchPaths(workflowDir, cacheDir, session string) error {
	if workflowDir == "" || cacheDir == "" || session == "" || !filepath.IsAbs(session) {
		return errors.New("workflow, cache, and absolute session paths are required")
	}
	info, err := os.Stat(session)
	if err != nil {
		return fmt.Errorf("opening search session: %w", err)
	}
	if !info.IsDir() {
		return errors.New("search session is not a directory")
	}
	return nil
}

func categoryKey(category searchCategory) string {
	return category.kind + ":" + category.qualifier
}

func searchReceiptPath(session string, index int) string {
	return filepath.Join(session, fmt.Sprintf("category-%d.json", index))
}

func searchFirstCategory(ctx context.Context, ghPath, token, session string, index int, kind string, category searchCategory, query string, perPage, limit int, pacer *searchPacer) (searchReceipt, error) {
	path := searchReceiptPath(session, index)
	var receipt searchReceipt
	if err := readSearchReceipt(path, &receipt); err == nil {
		if receipt.Kind != kind || receipt.Category != categoryKey(category) || receipt.Query != query || receipt.PerPage != perPage {
			return searchReceipt{}, errors.New("pending search receipt does not match the current query")
		}
		return receipt, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return searchReceipt{}, fmt.Errorf("reading pending search receipt: %w", err)
	}

	response, err := pacer.fetch(ctx, ghPath, token, query, perPage, 1)
	if err != nil {
		return searchReceipt{}, err
	}
	if len(response.Items) > limit {
		response.Items = response.Items[:limit]
	}
	receipt = searchReceipt{
		Kind: kind, Category: categoryKey(category), Query: query, PerPage: perPage,
		Loaded: len(response.Items), TotalCount: response.TotalCount, Items: response.Items,
	}
	if receipt.Loaded > 0 && receipt.Loaded < limit && receipt.Loaded < receipt.TotalCount {
		receipt.NextPage = 2
	}
	if err := writeSearchReceipt(path, receipt); err != nil {
		return searchReceipt{}, fmt.Errorf("saving pending search receipt: %w", err)
	}
	return receipt, nil
}


func searchMoreCategory(ctx context.Context, ghPath, token string, receipt *searchReceipt, limit int, pacer *searchPacer) error {
	for receipt.NextPage > 0 && receipt.NextPage <= 10 && receipt.Loaded < limit {
		page := receipt.NextPage
		response, err := pacer.fetch(ctx, ghPath, token, receipt.Query, receipt.PerPage, page)
		if err != nil {
			return err
		}
		addCount := len(response.Items)
		remaining := limit - receipt.Loaded
		if addCount > remaining {
			addCount = remaining
		}
		if addCount > 0 {
			receipt.Items = append(receipt.Items, response.Items[:addCount]...)
			receipt.Loaded += addCount
		}
		receipt.TotalCount = response.TotalCount
		receipt.NextPage = 0
		if addCount > 0 && receipt.Loaded < limit && receipt.Loaded < receipt.TotalCount {
			receipt.NextPage = page + 1
		}
	}
	return nil
}

func runCategoryTasks(ctx context.Context, count int, run func(context.Context, int) error) error {
	taskCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	var wait sync.WaitGroup
	var errMu sync.Mutex
	var firstErr error
	for i := range count {
		wait.Add(1)
		go func(index int) {
			defer wait.Done()
			if err := run(taskCtx, index); err != nil {
				errMu.Lock()
				if firstErr == nil {
					firstErr = err
				}
				errMu.Unlock()
				cancel()
			}
		}(i)
	}
	wait.Wait()
	return firstErr
}

// Share GitHub's reset time across the parallel continuation requests. The
// initially unknown allowance (including usage by other clients) is learned
// from response headers; retry a rate-limited page without losing prior pages.
type searchPacer struct {
	mu   sync.Mutex
	next time.Time
}

func (p *searchPacer) deferUntil(next time.Time) {
	p.mu.Lock()
	if next.After(p.next) {
		p.next = next
	}
	p.mu.Unlock()
}

func (p *searchPacer) fetch(ctx context.Context, ghPath, token, query string, perPage, page int) (searchAPIResponse, error) {
	for attempt := 0; ; attempt++ {
		p.mu.Lock()
		wait := time.Until(p.next)
		p.mu.Unlock()
		for wait > 0 {
			timer := time.NewTimer(wait)
			select {
			case <-ctx.Done():
				timer.Stop()
				return searchAPIResponse{}, ctx.Err()
			case <-timer.C:
			}
			p.mu.Lock()
			wait = time.Until(p.next)
			p.mu.Unlock()
		}
		response, retryAt, err := requestSearchPage(ctx, ghPath, token, query, perPage, page)
		p.deferUntil(retryAt)
		if err == nil || retryAt.IsZero() || attempt == 2 {
			return response, err
		}
	}
}

func searchRetryAt(headers textproto.MIMEHeader) time.Time {
	const maxWait = 2 * time.Minute
	now := time.Now()
	if secs, err := strconv.Atoi(headers.Get("Retry-After")); err == nil && secs >= 0 && secs < int(maxWait/time.Second) {
		return now.Add(time.Duration(secs+1) * time.Second)
	}
	if headers.Get("X-RateLimit-Remaining") == "0" {
		if reset, err := strconv.ParseInt(headers.Get("X-RateLimit-Reset"), 10, 64); err == nil {
			next := time.Unix(reset, 0).Add(time.Second)
			if next.Sub(now) <= maxWait {
				return maxTime(next, now.Add(time.Second))
			}
		}
	}
	return time.Time{}
}

func maxTime(a, b time.Time) time.Time {
	if a.After(b) {
		return a
	}
	return b
}

func requestSearchPage(ctx context.Context, ghPath, token, query string, perPage, page int) (searchAPIResponse, time.Time, error) {
	args := []string{
		"api", "--include", "--method", "GET", "search/issues",
		"-f", "q=" + query,
		"-f", "sort=updated",
		"-f", "order=desc",
		"-F", fmt.Sprintf("per_page=%d", perPage),
		"-F", fmt.Sprintf("page=%d", page),
	}
	output, err := runGH(ctx, ghPath, token, args...)
	reader := bufio.NewReader(bytes.NewReader(output))
	headers := textproto.NewReader(reader)
	status, headerErr := headers.ReadLine()
	if headerErr != nil || !strings.HasPrefix(status, "HTTP/") {
		return searchAPIResponse{}, time.Time{}, fmt.Errorf("missing GitHub search response headers: %v", err)
	}
	fields, headerErr := headers.ReadMIMEHeader()
	if headerErr != nil {
		return searchAPIResponse{}, time.Time{}, fmt.Errorf("reading GitHub search headers: %w", headerErr)
	}
	retryAt := searchRetryAt(fields)
	if err != nil {
		if !strings.Contains(status, " 403") && !strings.Contains(status, " 429") {
			retryAt = time.Time{}
		}
		return searchAPIResponse{}, retryAt, err
	}
	var response searchAPIResponse
	if err := json.NewDecoder(reader).Decode(&response); err != nil {
		return searchAPIResponse{}, time.Time{}, fmt.Errorf("decoding GitHub search page: %w", err)
	}
	if response.Items == nil || response.TotalCount < 0 {
		return searchAPIResponse{}, time.Time{}, errors.New("GitHub returned an invalid search page")
	}
	if response.Incomplete {
		return searchAPIResponse{}, time.Time{}, errors.New("GitHub returned an incomplete search page")
	}
	return response, retryAt, nil
}

func runGH(ctx context.Context, ghPath, token string, args ...string) ([]byte, error) {
	if ghPath == "" {
		var err error
		ghPath, err = exec.LookPath("gh")
		if err != nil {
			return nil, fmt.Errorf("finding GitHub CLI: %w", err)
		}
	}
	cmd := exec.CommandContext(ctx, ghPath, args...)
	cmd.Env = searchEnvironment(token)
	output, err := cmd.Output()
	if err != nil {
		return output, fmt.Errorf("GitHub CLI command failed: %w", err)
	}
	return output, nil
}

func searchEnvironment(token string) []string {
	env := os.Environ()
	filtered := env[:0]
	for _, value := range env {
		name, _, _ := strings.Cut(value, "=")
		if name != "GH_TOKEN" && name != "GITHUB_TOKEN" && name != "GH_HOST" && name != "GH_PROMPT_DISABLED" && name != "GH_NO_UPDATE_NOTIFIER" {
			filtered = append(filtered, value)
		}
	}
	return append(filtered,
		"GH_TOKEN="+token,
		"GH_HOST=github.com",
		"GH_PROMPT_DISABLED=1",
		"GH_NO_UPDATE_NOTIFIER=1",
	)
}

func readSearchReceipt(path string, receipt *searchReceipt) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(data, receipt); err != nil {
		return err
	}
	if receipt.Items == nil || receipt.Loaded != len(receipt.Items) || receipt.Loaded < 0 || receipt.TotalCount < 0 || receipt.NextPage < 0 || receipt.PerPage < 1 || receipt.PerPage > 100 {
		return errors.New("invalid pending search receipt")
	}
	return nil
}

func writeSearchReceipt(path string, receipt searchReceipt) error {
	data, err := json.Marshal(receipt)
	if err != nil {
		return err
	}
	return atomicSearchWrite(path, data, 0600)
}

func atomicSearchWrite(path string, data []byte, mode os.FileMode) error {
	file, err := os.CreateTemp(filepath.Dir(path), ".hubfred-search-*")
	if err != nil {
		return err
	}
	temporary := file.Name()
	defer os.Remove(temporary)
	if err := file.Chmod(mode); err != nil {
		_ = file.Close()
		return err
	}
	if _, err := file.Write(data); err != nil {
		_ = file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	return os.Rename(temporary, path)
}

type mergedSearchItem struct {
	row    item
	author string
	repo   string
	number int
	draft  bool
}

func formatSearchItems(receipts []searchReceipt, categories []searchCategory, kind, workflowDir, cacheDir string) ([]item, error) {
	states := []string{"ready", "draft"}
	if kind == "issues" {
		states = []string{"issue"}
	} else if kind == "all" {
		states = []string{"ready", "draft", "issue"}
	}
	iconDir, err := prepareSearchIcons(workflowDir, cacheDir, states)
	if err != nil {
		return nil, err
	}

	itemCount := 0
	for i := range receipts {
		itemCount += len(receipts[i].Items)
	}
	merged := make([]mergedSearchItem, 0, itemCount)
	byURL := make(map[string]int, itemCount)
	for i, receipt := range receipts {
		for j := range receipt.Items {
			raw := &receipt.Items[j]
			if index, exists := byURL[raw.HTMLURL]; exists {
				merged[index].row.Reasons = addReason(merged[index].row.Reasons, categories[i].reason)
				continue
			}
			row, author, repo, state, err := normalizeSearchItem(raw, categories[i].reason, kind)
			if err != nil {
				return nil, err
			}
			row.Icon.Path = filepath.Join(iconDir, fmt.Sprintf("%d-%s.png", repositoryColor(repo), state))
			byURL[row.UID] = len(merged)
			merged = append(merged, mergedSearchItem{row: row, author: author, repo: repo, number: raw.Number, draft: state == "draft"})
		}
	}

	for i := range merged {
		row := &merged[i]
		sort.Strings(row.row.Reasons)
		row.row.Subtitle = fmt.Sprintf("%s#%d · %s · %s · %s", row.repo, row.number, row.author,
			row.row.UpdatedAt.Local().Format("2006-01-02 15:04"), strings.Join(row.row.Reasons, " · "))
		if row.draft {
			row.row.Subtitle += " · Draft"
		}
	}
	sort.SliceStable(merged, func(i, j int) bool {
		if merged[i].row.UpdatedAt.Equal(merged[j].row.UpdatedAt) {
			return merged[i].row.UID > merged[j].row.UID
		}
		return merged[i].row.UpdatedAt.After(merged[j].row.UpdatedAt)
	})
	items := make([]item, len(merged))
	for i := range merged {
		items[i] = merged[i].row
	}
	return items, nil
}

func normalizeSearchItem(raw *searchAPIItem, reason, kind string) (item, string, string, string, error) {
	if !itemURL.MatchString(raw.HTMLURL) || raw.UpdatedAt.IsZero() {
		return item{}, "", "", "", errors.New("invalid GitHub search item URL or update time")
	}
	repo, ok := strings.CutPrefix(raw.RepositoryURL, "https://api.github.com/repos/")
	if !ok || strings.Count(repo, "/") != 1 {
		return item{}, "", "", "", errors.New("GitHub search item has no repository name")
	}
	state := "issue"
	if strings.Contains(raw.HTMLURL, "/pull/") {
		state = "ready"
		if raw.Draft {
			state = "draft"
		}
	}
	var labels []string
	if kind != "prs" {
		labels = make([]string, 0, len(raw.Labels))
		for _, label := range raw.Labels {
			labels = append(labels, label.Name)
		}
	}
	var row item
	row.UID = raw.HTMLURL
	row.Arg = raw.HTMLURL
	row.Title = raw.Title
	row.UpdatedAt = raw.UpdatedAt
	row.Reasons = []string{reason}
	row.Kind = "kindpr"
	if state == "issue" {
		row.Kind = "kindissue"
	}
	row.Match = fmt.Sprintf("%s %s #%d %d", raw.Title, repo, raw.Number, raw.Number)
	row.Body = &raw.Body
	row.Labels = labels
	return row, raw.User.Login, repo, state, nil
}

func addReason(reasons []string, reason string) []string {
	for _, existing := range reasons {
		if existing == reason {
			return reasons
		}
	}
	return append(reasons, reason)
}

func repositoryColor(repository string) int {
	var hash uint64
	for _, character := range repository {
		if character >= 'A' && character <= 'Z' {
			character += 'a' - 'A'
		}
		hash = (hash*31 + uint64(character)) % 2147483647
	}
	return int(hash % uint64(len(iconColors)))
}

func prepareSearchIcons(workflowDir, cacheDir string, states []string) (string, error) {
	iconDir := filepath.Join(cacheDir, "octicons-v5")
	if err := os.MkdirAll(iconDir, 0755); err != nil {
		return "", fmt.Errorf("creating icon cache: %w", err)
	}
	assets := map[string]string{
		"ready": "git-pull-request-16.svg",
		"draft": "git-pull-request-draft-16.svg",
		"issue": "issue-opened-16.svg",
	}
	pending := make([]string, 0, len(iconColors)*len(states))
	for index, color := range iconColors {
		for _, state := range states {
			pngPath := filepath.Join(iconDir, fmt.Sprintf("%d-%s.png", index, state))
			if info, err := os.Stat(pngPath); err == nil && info.Size() > 0 {
				continue
			} else if err != nil && !errors.Is(err, os.ErrNotExist) {
				return "", fmt.Errorf("checking cached icon: %w", err)
			}
			svgPath := filepath.Join(iconDir, fmt.Sprintf("%d-%s.svg", index, state))
			contents, err := os.ReadFile(filepath.Join(workflowDir, "octicons", assets[state]))
			if err != nil {
				return "", fmt.Errorf("reading workflow icon: %w", err)
			}
			svg := string(contents)
			svg = strings.Replace(svg, `width="16" height="16"`, `width="64" height="64"`, 1)
			svg = strings.Replace(svg, `viewBox="0 0 16 16"`, `viewBox="-1.142857 -1.142857 18.285714 18.285714"`, 1)
			svg = strings.Replace(svg, "<svg ", `<svg fill="#`+color+`" `, 1)
			if err := atomicSearchWrite(svgPath, []byte(svg), 0644); err != nil {
				return "", fmt.Errorf("writing cached icon source: %w", err)
			}
			pending = append(pending, svgPath)
		}
	}
	if len(pending) > 0 {
		args := []string{"-s", "format", "png"}
		args = append(args, pending...)
		args = append(args, "--out", iconDir)
		if output, err := exec.Command("/usr/bin/sips", args...).CombinedOutput(); err != nil {
			return "", fmt.Errorf("converting workflow icons: %w: %s", err, strings.TrimSpace(string(output)))
		}
	}
	return iconDir, nil
}
