def category_reason($category):
  if $category == "prs:author" or $category == "issues:author" then "Authored"
  elif $category == "prs:user-review-requested" then "Review requested"
  elif $category == "issues:assignee" then "Assigned"
  elif $category == "issues:mentions" then "Mentioned"
  elif $category == "issues:commenter" then "Commented"
  else error("unknown GitHub search category")
  end;

def repository_color:
  (ascii_downcase | explode) as $characters
  | reduce $characters[] as $character (0; ((. * 31 + $character) % 2147483647))
  | . % 6;

def render_item($receipt; $raw; $kind; $icon_dir):
  if (($raw.html_url | type) != "string") or (($raw.updated_at | type) != "string") or
     (($raw.number | type) != "number") or (($raw.number | floor) != $raw.number) then
    error("invalid GitHub search item")
  else . end
  | ($raw.repository_url
      | if type == "string" and startswith("https://api.github.com/repos/") then
          ltrimstr("https://api.github.com/repos/")
        else error("GitHub search item has no repository name")
        end) as $repository
  | if (($repository | split("/")) | length) != 2 or ($repository | split("/") | any(. == "")) then
      error("GitHub search item has no repository name")
    else . end
  | ($raw.html_url
      | if test("^https://github[.]com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(pull|issues)/[0-9]+$") then .
        else error("invalid GitHub search item URL")
        end) as $url
  | ($url | split("/")[-2]) as $route
  | ($raw.user.login // "") as $author
  | ($raw.number | tostring) as $number
  | (if $route == "pull" then
       if ($raw.draft // false) then "draft" else "ready" end
     else "issue" end) as $state
  | category_reason($receipt.category) as $reason
  | {
      uid: $url,
      arg: $url,
      title: ($raw.title // ""),
      _repository: $repository,
      _author: $author,
      _number: $raw.number,
      _draft: ($state == "draft"),
      match: (($raw.title // "") + " " + $repository + " #" + $number + " " + $number),
      updatedAt: $raw.updated_at,
      reasons: [$reason],
      labels: (if $kind == "prs" then [] else [($raw.labels // [])[] | (.name // "")] end),
      kind: (if $state == "issue" then "kindissue" else "kindpr" end),
      icon: {path: ($icon_dir + "/" + (($repository | repository_color) | tostring) + "-" + $state + ".png")},
      body: ($raw.body // "")
    }
  | if $kind == "prs" or (.labels | length) == 0 then del(.labels) else . end;

[ .[] as $receipt
  | $receipt.items[] as $raw
  | render_item($receipt; $raw; $kind; $iconDir)
]
| reduce .[] as $row (
    {items: [], seen: {}};
    if .seen[$row.uid] != null then
      (.seen[$row.uid]) as $index
      | (.items[$index].reasons + $row.reasons | unique) as $reasons
      | if ($row.updatedAt | fromdateiso8601) >
           (.items[$index].updatedAt | fromdateiso8601) then
          .items[$index] = ($row | .reasons = $reasons)
        else
          .items[$index].reasons = $reasons
        end
    else
      .seen[$row.uid] = (.items | length)
      | .items += [$row]
    end
  )
| .items
| map(
    .reasons |= sort
    | .subtitle = (
        ._repository + "#" + (._number | tostring) + " · " + ._author + " · " +
        (.updatedAt | fromdateiso8601 | strflocaltime("%Y-%m-%d %H:%M")) +
        " · " + (.reasons | join(" · ")) +
        (if ._draft then " · Draft" else "" end)
      )
    | del(._repository, ._author, ._number, ._draft)
  )
| sort_by([(.updatedAt | fromdateiso8601), .uid])
| reverse
| {items: .}
