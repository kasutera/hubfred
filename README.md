# Alfred: My GitHub PRs and Issues

Alfred で `pr` に続けてスペースを入力すると、GitHub CLI でログイン中の github.com アカウントを使って Open PR を表示する。タイトル、`owner/repo`、PR 番号（`123` または `#123`）で絞り込み、Enter で既定のブラウザに開く。

`prs` → Enter で Alfred 6 の専用画面を開く。上部のメニューで全件・自分の作成 PR・レビュー依頼を切り替え、検索欄で絞り込める。↑↓ またはクリックで選ぶと右側に PR 本文を表示し、検索欄で Enter を押すか行をダブルクリックするとブラウザに開く。
ダッシュボードと本文プレビューは、macOS のライト／ダークモードに合わせた不透明な背景で表示する。

`is` に続けてスペースを入力すると Issue の簡易一覧、`iss` → Enter で Issue の専用画面を開く。アクセスできる全リポジトリから、自分に割り当てられた・自分が作成した・自分がメンションされた・自分がコメントした Open Issue を、重複を除いて更新日時順に表示する。専用画面では関わり方を切り替えられ、左の一覧にラベル、右に Markdown の本文を表示する。ラベルも検索欄で絞り込める。

- 本文は Pandoc の GitHub Flavored Markdown（GFM）で変換し、WebKit で表示する。表・タスクリスト・コードブロックなどに対応。生 HTML は描画せず、画像は自動取得しない。Markdown の画像や GitHub の添付画像はリンクからブラウザで開ける。非公開の添付画像には、ブラウザでの GitHub ログインが必要。
- `prs` と `iss` は一覧と本文を別々にローカル保存する。取得後30秒未満は通信せず、30秒〜10分は前回の一覧を先に表示して裏で更新する。更新に失敗しても表示済みの一覧は保持する。初回・10分経過後・認証設定変更後は GitHub の応答を待つ。

- 自分が作成した PR（Draft を含む）と、自分個人に現在レビュー依頼が来ている PR が対象。チーム経由の依頼は含めない。
- アクセスできるリポジトリを横断し、更新日時の新しい順に表示する。GitHub Search の上限は条件ごとに 1,000 件。
- 各行に作成者と最終更新日時（Mac の現地時刻、`YYYY-MM-DD HH:mm`）を表示する。Draft、通常の PR、Issue は形が異なる [GitHub Octicons v19.19.0](https://github.com/primer/octicons/tree/v19.19.0/icons) の公式アイコン（[MIT](workflow/octicons/LICENSE)）を使う。色はリポジトリごとに固定（12 色。同じ色になる場合もある）。
- 関わり方ごとの検索は並列に実行する。`pr` と `is` は Alfred が前回の一覧を即表示し、30秒を過ぎて開き直したときは裏で更新する。文字入力中の絞り込みはローカルで行う。
- GitHub CLI のアカウントを切り替えた直後、`pr` と `is` のキャッシュは Alfred で `reload` を実行して消せる。`prs` と `iss` は GitHub CLI の認証設定が変わると前のキャッシュを使わない。

## インストール

専用画面には Alfred 6 と Pandoc（`brew install pandoc`）、すべての入口に Powerpack と github.com にログイン済みの GitHub CLI (`gh`) が必要。Alfred の既定の設定保存先を使用している場合は、このリポジトリのルートで以下を実行する。設定を同期している場合は、`dest` の `Alfred.alfredpreferences` のパスを同期先に合わせる。

```bash
dest="$HOME/Library/Application Support/Alfred/Alfred.alfredpreferences/workflows/user.workflow.0465F0DE-9C05-4575-92F2-3454A56B8536"
ditto workflow "$dest"
```

Alfred に反映されない場合は、Alfred を再起動する。更新時も同じ手順でコピーする。
