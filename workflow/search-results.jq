def repo_color:
    ascii_downcase | explode
    | reduce .[] as $c (0; (. * 31 + $c) % 2147483647)
    | . % $color_count;

def local_timestamp:
    fromdateiso8601 | strflocaltime("%Y-%m-%d %H:%M");

($reasons | split("|")) as $relations
| [to_entries[] | .key as $i | .value[] | . + {reason: $relations[$i]}]
| group_by(.url)
| map(.[0] + {reasons: (map(.reason) | unique)})
| sort_by(.updatedAt) | reverse
| (if $mode == "picker" then .[:$search_limit] else . end)
| {items: map(.repository.nameWithOwner as $repo
    | (if $kind == "issues" then "issue" elif .isDraft then "draft" else "ready" end) as $state
    | {title,
       subtitle: "\($repo)#\(.number) · \(.author.login) · \(.updatedAt | local_timestamp) · \(.reasons | join(" · "))\(if .isDraft then " · Draft" else "" end)",
       match: "\(.title) \($repo) #\(.number) \(.number)",
       uid: .url,
       arg: .url,
       icon: {path: "\($icon_dir)/\($repo | repo_color)-\($state).png"}}
      + if $mode == "dashboard" then {body, reasons, labels: [.labels[]?.name]} else {} end)}
| if .items == [] then
    {items: [{title: "No matching open \($noun)", subtitle: "No matching items on github.com", valid: false}]}
  else . end
| . + {cache: {seconds: 30, loosereload: true}, skipknowledge: true}
