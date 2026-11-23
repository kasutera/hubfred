package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode"

	"golang.org/x/text/cases"
	"golang.org/x/text/unicode/norm"
)

func runPicker(ctx context.Context, uiDir, kind, query string) (jsonObject, error) {
	unfiltered := strings.TrimSpace(query) == ""
	if unfiltered {
		query = ""
	}
	store, err := newDashboardStore(kind)
	if err != nil {
		return nil, err
	}
	if !unfiltered {
		store.Path = store.BroadPath
		store.Scope = ""
	}
	if store.GH == "" {
		return pickerMessage("GitHub CLI not found", "Install gh, then sign in to github.com."), nil
	}

	token, identity, err := store.credential(ctx)
	if err != nil || identity == "" || (os.Getenv("hubfred_refresh_identity") != "" && os.Getenv("hubfred_refresh_identity") != identity) {
		return pickerMessage("Could not load GitHub results", "Check your GitHub CLI login and reopen the picker."), nil
	}

	cachedRows, age, err := store.read(ctx, identity, unfiltered)
	if err != nil {
		cachedRows, age = nil, store.Stale
	}
	cacheMode := "dashboard"
	if unfiltered {
		cacheMode = "picker"
	}
	refreshing := os.Getenv("hubfred_refresh_mode") == cacheMode
	if age < store.Fresh {
		return pickerResponse(cachedRows, query, false, identity, cacheMode, kind), nil
	}
	if !refreshing && age < store.Stale {
		return pickerResponse(cachedRows, query, true, identity, cacheMode, kind), nil
	}
	if !refreshing && !unfiltered {
		return pickerResponse(nil, query, true, identity, cacheMode, kind), nil
	}

	limit := 1000
	if unfiltered {
		limit = 10
	}
	rows, err := fetchPickerRows(ctx, uiDir, store, token, kind, limit)
	_, currentIdentity, authErr := store.credential(ctx)
	if authErr != nil || currentIdentity != identity {
		return pickerMessage("Could not load GitHub results", "GitHub CLI login changed. Reopen the picker."), nil
	}
	if err != nil {
		if age < store.Stale {
			return pickerResponse(cachedRows, query, false, identity, cacheMode, kind), nil
		}
		return pickerMessage("Could not load GitHub results", "Check the network and your GitHub CLI login."), nil
	}
	if unfiltered && len(rows) > 10 {
		rows = rows[:10]
	}
	if err := store.savePicker(ctx, identity, rows, unfiltered); err != nil {
		return nil, err
	}
	return pickerResponse(rows, query, false, identity, cacheMode, kind), nil
}

func fetchPickerRows(ctx context.Context, uiDir string, store dashboardStore, token, kind string, limit int) ([]item, error) {
	session, err := os.MkdirTemp("", "hubfred-picker.")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(session)

	workflowDir := filepath.Dir(uiDir)
	rows, more, err := searchFirst(ctx, store.GH, token, workflowDir, store.Dir, kind, session, limit, time.Time{})
	if err != nil {
		return nil, err
	}
	if more {
		return searchMore(ctx, store.GH, token, workflowDir, store.Dir, kind, session, limit)
	}
	return rows, nil
}

func pickerResponse(rows []item, query string, rerun bool, identity, mode, kind string) jsonObject {
	var filtered []item
	if strings.TrimSpace(query) != "" {
		filtered = filterPickerRows(rows, query)
	} else {
		filtered = rows
	}

	items := make([]jsonObject, 0, min(len(filtered), 10))
	for i := range filtered {
		row := &filtered[i]
		if row.Arg == "" {
			continue
		}
		items = append(items, jsonObject{
			"title": row.Title, "subtitle": row.Subtitle, "uid": row.UID, "arg": row.Arg,
			"icon": row.Icon,
		})
		if len(items) == 10 {
			break
		}
	}
	if len(items) == 0 {
		if strings.TrimSpace(query) != "" {
			title := "No matching open items"
			if rerun {
				title = "Searching GitHub…"
			}
			items = append(items, jsonObject{"title": title, "valid": false})
		} else {
			items = append(items, jsonObject{
				"title": "No matching open " + pickerNoun(kind),
				"subtitle": "No matching items on github.com", "valid": false,
			})
		}
	}
	response := jsonObject{"items": items, "skipknowledge": true}
	if rerun {
		delay := 0.1
		if strings.TrimSpace(query) != "" {
			delay = 0.3
		}
		response["rerun"] = delay
		response["variables"] = jsonObject{"hubfred_refresh_identity": identity, "hubfred_refresh_mode": mode}
	}
	return response
}

func pickerMessage(title, subtitle string) jsonObject {
	return jsonObject{"items": []jsonObject{{"title": title, "subtitle": subtitle, "valid": false}}}
}

func pickerNoun(kind string) string {
	switch kind {
	case "prs":
		return "PRs"
	case "issues":
		return "Issues"
	case "all":
		return "PRs and issues"
	default:
		return "items"
	}
}

// filterPickerRows follows the legacy picker's query-wide diacritic-folding
// rule and literal, case-insensitive start-of-whitespace-word matching.
func filterPickerRows(rows []item, query string) []item {
	query = norm.NFD.String(query)
	fold := cases.Fold()
	terms := strings.Fields(fold.String(query))
	foldMarks := true
	for _, r := range query {
		if unicode.IsMark(r) {
			foldMarks = false
			break
		}
	}

	// Snapshots are already ordered by update time, including legacy snapshots.
	matches := make([]item, 0, min(len(rows), 10))
	for i := range rows {
		row := &rows[i]
		if row.Arg == "" {
			continue
		}
		text := norm.NFD.String(fold.String(row.Match))
		repo := fold.String(pickerRepositoryName(row.UID))
		if foldMarks {
			text = stripPickerMarks(text)
			repo = stripPickerMarks(repo)
		}
		matched := true
		for _, term := range terms {
			if !pickerHasWordPrefix(text, term) && !pickerHasWordPrefix(repo, term) {
				matched = false
				break
			}
		}
		if matched {
			matches = append(matches, *row)
			if len(matches) == 10 {
				break
			}
		}
	}
	return matches
}

func pickerRepositoryName(uid string) string {
	path := strings.TrimPrefix(uid, "https://github.com/")
	_, remainder, ok := strings.Cut(path, "/")
	if !ok {
		return ""
	}
	repository, _, _ := strings.Cut(remainder, "/")
	return repository
}

func stripPickerMarks(value string) string {
	hasMark := false
	for _, r := range value {
		if unicode.IsMark(r) {
			hasMark = true
			break
		}
	}
	if !hasMark {
		return value
	}
	var stripped strings.Builder
	stripped.Grow(len(value))
	for _, r := range value {
		if !unicode.IsMark(r) {
			stripped.WriteRune(r)
		}
	}
	return stripped.String()
}

func pickerHasWordPrefix(text, term string) bool {
	for word := range strings.FieldsSeq(text) {
		if strings.HasPrefix(word, term) {
			return true
		}
	}
	return false
}
