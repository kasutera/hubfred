package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

type item struct {
	UID       string    `json:"uid"`
	Arg       string    `json:"arg"`
	Title     string    `json:"title"`
	Subtitle  string    `json:"subtitle"`
	Match     string    `json:"match"`
	UpdatedAt time.Time `json:"updatedAt,omitzero"`
	Reasons   []string  `json:"reasons,omitempty"`
	Labels    []string  `json:"labels,omitempty"`
	Kind      string    `json:"kind,omitempty"`
	Icon      struct {
		Path string `json:"path"`
	} `json:"icon"`
	Body *string `json:"body,omitempty"`
}

type jsonObject = map[string]any

type dashboard struct {
	store   dashboardStore
	uiDir   string
	kind    string
	noun    string
	reasons []string
	session string
}

type refreshScope struct {
	Identity string
	Limit    int
	Days     int
	Cutoff   time.Time
}

const (
	preparing   = "pending"
	ready       = "ready"
	unavailable = "unavailable"
	blankHTML   = "<!doctype html><html><body></body></html>"
	loadMore    = "Loading more results…"
	filter      = "{value:category.selected.value} {value:query.text}"
)

var itemURL = regexp.MustCompile(`^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(pull|issues)/[0-9]+$`)

func main() {
	args := os.Args[1:]
	response, err := run(context.Background(), args)
	if err == nil && response != nil {
		err = json.NewEncoder(os.Stdout).Encode(response)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string) (jsonObject, error) {
	if len(args) == 0 {
		return nil, fmt.Errorf("dashboard action required")
	}
	phase := args[0]
	if phase == "picker" {
		if len(args) != 3 {
			return nil, fmt.Errorf("picker requires a kind and query")
		}
		uiDir, err := os.Getwd()
		if err != nil {
			return nil, err
		}
		return runPicker(ctx, uiDir, args[1], args[2])
	}
	session := sessionPath(os.Getenv("dashboard_session"))
	if phase == "quit" {
		if session != "" {
			return nil, os.RemoveAll(session)
		}
		return nil, nil
	}
	uiDir, err := os.Getwd()
	if err != nil {
		return nil, err
	}
	kind := os.Getenv("dashboard_kind")
	if kind == "" {
		kind = "prs"
	}
	d := dashboard{uiDir: uiDir, kind: kind, session: session}
	issueReasons := []string{"Assigned", "Authored", "Mentioned", "Commented"}
	switch kind {
	case "prs":
		d.noun, d.reasons = "PRs", []string{"Authored", "Review requested"}
	case "issues":
		d.noun, d.reasons = "issues", issueReasons
	case "all":
		d.noun, d.reasons = "PRs and issues", append(issueReasons, "Review requested")
	default:
		return nil, fmt.Errorf("invalid dashboard kind %q", kind)
	}
	if phase == "preview" {
		if len(args) < 2 || !itemURL.MatchString(args[1]) {
			return previewResponse("", blankHTML), nil
		}
		if len(args) > 2 {
			switch args[2] {
			case preparing:
				return previewResponse(args[1], "<!doctype html><meta charset=utf-8><p>Preparing preview…</p>"), nil
			case unavailable:
				return previewResponse(args[1], "<p>Preview unavailable. Open the item on GitHub to read its description.</p>"), nil
			}
		}
	} else if phase != "cached" && session == "" {
		return jsonObject{}, nil
	}
	d.store, err = newDashboardStore(kind)
	if err != nil {
		if phase == "preview" {
			return previewResponse(args[1], "<p>Preview unavailable.</p>"), nil
		}
		return d.failure(), nil
	}
	token, identity, err := d.store.credential(ctx)
	if phase == "preview" {
		return d.preview(ctx, identity, args[1]), nil
	}
	if err != nil || identity == "" {
		if session != "" {
			_ = os.RemoveAll(session)
		}
		return d.failure(), nil
	}
	switch phase {
	case "cached":
		return d.preload(ctx, identity), nil
	case "first", "more", "save":
		return d.refresh(ctx, phase, token, identity), nil
	default:
		return nil, fmt.Errorf("unknown dashboard action %q", phase)
	}
}

func sessionPath(path string) string {
	path = filepath.Clean(path)
	if filepath.Dir(path) != filepath.Clean(os.TempDir()) || !strings.HasPrefix(filepath.Base(path), "hubfred-dashboard.") {
		return ""
	}
	return path
}

func writeJSON(path string, value any) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		return err
	}
	if err = json.NewEncoder(f).Encode(value); err != nil {
		_ = f.Close()
		return err
	}
	return f.Close()
}

func readJSON(path string, value any) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	return json.NewDecoder(f).Decode(value)
}

func (d dashboard) pickerFallback(ctx context.Context, identity string) []item {
	rows, age, err := d.store.read(ctx, identity, true)
	if err != nil || age >= d.store.Stale {
		return nil
	}
	eligible := rows[:0]
	for i := range rows {
		if d.visible(rows[i]) {
			eligible = append(eligible, rows[i])
			if len(eligible) == d.store.Limit {
				break
			}
		}
	}
	return eligible
}

func (d dashboard) visible(row item) bool {
	return row.Arg != "" && (d.store.Cutoff.IsZero() || !row.UpdatedAt.Before(d.store.Cutoff))
}

func (d dashboard) preload(ctx context.Context, identity string) jsonObject {
	rows, age, err := d.store.read(ctx, identity, false)
	state := ready
	if err != nil || age >= d.store.Stale {
		rows = d.pickerFallback(ctx, identity)
		state = preparing
	}
	if err != nil || age >= d.store.Fresh {
		d.session, err = os.MkdirTemp("", "hubfred-dashboard.")
		if err != nil {
			return d.failure()
		}
		if err = writeJSON(filepath.Join(d.session, "scope.json"), refreshScope{
			Identity: identity, Limit: d.store.Limit, Days: d.store.Days, Cutoff: d.store.Cutoff,
		}); err != nil {
			_ = os.RemoveAll(d.session)
			return d.failure()
		}
	}
	return d.display(rows, state, "", "", true)
}

func (d dashboard) refresh(ctx context.Context, phase, token, identity string) jsonObject {
	var scope refreshScope
	if err := readJSON(filepath.Join(d.session, "scope.json"), &scope); err != nil {
		return jsonObject{}
	}
	next := ""
	defer func() {
		if next == "" {
			_ = os.RemoveAll(d.session)
		}
	}()
	if scope.Identity != identity || scope.Limit != d.store.Limit || scope.Days != d.store.Days {
		return d.failure()
	}
	var rows []item
	result := filepath.Join(d.session, "result.json")
	if phase == "save" {
		if err := readJSON(result, &rows); err != nil {
			return d.failure()
		}
		if err := d.store.save(ctx, identity, rows); err != nil {
			return d.display(rows, unavailable, "Could not save results", "", false)
		}
		return d.display(rows, ready, "", "", false)
	}

	var more bool
	var err error
	workflowDir := filepath.Dir(d.uiDir)
	if phase == "first" {
		rows, more, err = searchFirst(ctx, d.store.GH, token, workflowDir, d.store.Dir, d.kind, d.session, scope.Limit, scope.Cutoff)
	} else {
		rows, err = searchMore(ctx, d.store.GH, token, workflowDir, d.store.Dir, d.kind, d.session, scope.Limit)
	}
	if _, current, authErr := d.store.credential(ctx); authErr != nil || current != identity {
		return d.failure()
	}
	if err != nil {
		if phase == "more" {
			if err := readJSON(result, &rows); err == nil {
				return d.display(rows, unavailable, "Could not load more results", "", false)
			}
		} else if _, age, err := d.store.read(ctx, identity, false); err == nil && age < d.store.Stale {
			return jsonObject{}
		} else if fallback := d.pickerFallback(ctx, identity); len(fallback) > 0 {
			return d.display(fallback, unavailable, "Could not load GitHub "+d.noun, "", false)
		}
		return d.failure()
	}
	if err := writeJSON(result, rows); err != nil {
		return d.failure()
	}
	next, status := "save", ""
	if more {
		next, status = "more", loadMore
	}
	return d.display(rows, preparing, status, next, false)
}

func tokenFor(reason string) string { return "relation" + strings.ToLower(strings.ReplaceAll(reason, " ", "")) }

type listRow struct {
	UID          string     `json:"uid"`
	PreviewState string     `json:"previewState"`
	Title        string     `json:"title.text"`
	Subtitle     string     `json:"subtitle.text"`
	Match        string     `json:"match"`
	Icon         glyphImage `json:"glyph.image"`
}

type glyphImage struct {
	Type string `json:"type"`
	Src  string `json:"src"`
}

func listData(rows []listRow) jsonObject {
	return jsonObject{"type": "basic", "src": rows, "filter": jsonObject{
		"type": "basic", "args": "match", "match": filter, "matchmode": "wordmatchanyorder",
	}}
}

func (d dashboard) display(rows []item, previewState, status, next string, configure bool) jsonObject {
	ids := jsonObject{"loadstatus": jsonObject{"text": status}}
	out := jsonObject{"update": jsonObject{"relayout": !configure, "ids": ids}}
	if configure {
		categories := []jsonObject{{"text": "All " + d.noun, "value": "allitems"}}
		if d.kind == "all" {
			categories = append(categories, jsonObject{"text": "PRs", "value": "kindpr"}, jsonObject{"text": "Issues", "value": "kindissue"})
		}
		for _, reason := range d.reasons {
			categories = append(categories, jsonObject{"text": reason, "value": tokenFor(reason)})
		}
		ids["category"] = jsonObject{"items": categories, "selected": "allitems"}
		out["variables"] = jsonObject{"dashboard_session": d.session}
	}
	if next != "" {
		out["pulse"] = jsonObject{"src": "load.sh", "args": []string{next}, "now": true}
	}
	list := make([]listRow, 0, len(rows))
	for i := range rows {
		row := &rows[i]
		if !d.visible(*row) {
			continue
		}
		subtitle := row.Subtitle
		if len(row.Labels) != 0 {
			subtitle = "Labels: " + strings.Join(row.Labels, ", ") + " · " + subtitle
		}
		var match strings.Builder
		match.WriteString("allitems")
		if d.kind == "all" && row.Kind != "" {
			match.WriteByte(' ')
			match.WriteString(row.Kind)
		}
		for _, reason := range row.Reasons {
			match.WriteByte(' ')
			match.WriteString(tokenFor(reason))
		}
		match.WriteByte(' ')
		match.WriteString(row.Match)
		for _, label := range row.Labels {
			match.WriteByte(' ')
			match.WriteString(label)
		}
		list = append(list, listRow{
			UID: row.UID, PreviewState: previewState, Title: row.Title, Subtitle: subtitle,
			Match: match.String(), Icon: glyphImage{Type: "file", Src: row.Icon.Path},
		})
	}
	if configure && len(list) == 0 {
		return out
	}
	placeholder := "No matching open " + d.noun
	if status != "" {
		placeholder = status
	}
	data := jsonObject{"placeholder": placeholder, "data": listData(list)}
	if !configure {
		data["select"] = "{var:dashboard_selection}"
	}
	ids["prs"] = data
	return out
}

func (d dashboard) failure() jsonObject {
	return jsonObject{"update": jsonObject{"relayout": true, "ids": jsonObject{
		"prs":        jsonObject{"placeholder": "Could not load GitHub " + d.noun, "data": listData([]listRow{})},
		"loadstatus": jsonObject{"text": ""},
		"preview":    jsonObject{"text": blankHTML},
	}}}
}

func previewResponse(url, html string) jsonObject {
	return jsonObject{"variables": jsonObject{"dashboard_selection": url},
		"update": jsonObject{"ids": jsonObject{"preview": jsonObject{"text": html}}}}
}

func (d dashboard) preview(ctx context.Context, identity, url string) jsonObject {
	body := "Preview unavailable."
	if identity != "" {
		if text, found, err := d.store.body(ctx, identity, url); err == nil && found {
			body = text
			if body == "" {
				body = "No description."
			}
		}
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/usr/bin/osascript", "-l", "JavaScript", "render-markdown.js", filepath.Join(d.uiDir, "vendor/marked/marked.umd.js"), url)
	cmd.Dir = d.uiDir
	cmd.Stdin = strings.NewReader(body)
	html, err := cmd.Output()
	if err != nil {
		html = []byte("<p>Preview unavailable. Open the item on GitHub to read its description.</p>")
		if ctx.Err() == context.DeadlineExceeded {
			html = []byte("<p>Preview timed out. Open the item on GitHub to read its description.</p>")
		}
	}
	page, err := os.ReadFile(filepath.Join(d.uiDir, "preview.html"))
	if err != nil {
		return previewResponse(url, "<p>Preview unavailable.</p>")
	}
	return previewResponse(url, string(bytes.Join([][]byte{page, html}, nil)))
}
