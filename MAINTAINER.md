# メンテナ向けガイド

## ローカル開発

リポジトリのルートで Node.js 24、npm、`zip` を使ってビルドする。`npm ci` は初回とロックファイルが変わったときに実行する。

```bash
npm ci --ignore-scripts
npm run package
open dist/Hubfred.alfredworkflow
```

`npm run package` は Git インデックスにある `workflow/` のファイルを作業ツリーから読み取るため、既存ファイルの未コミット変更も含む。追加したファイルは先に Git の追跡対象にする。Marked の JavaScript とライセンスはロック済み npm 配布物からパッケージにだけ同梱する。

## README のスクリーンショット

macOS 上で Alfred 6 と Swift（Xcode Command Line Tools）を使う。端末に画面収録と Alfred の操作を許可する。撮影時は macOS をライトモードにし、Alfred のテーマを **Alfred Classic** にする。README の画像は Retina（2×）で撮影した。

```bash
npm ci --ignore-scripts
npm run screenshots -- --prepare
open dist/Hubfred-Screenshots.alfredworkflow
npm run screenshots
```

`--prepare` とインポートは初回のみ。2回目からは `npm run screenshots` が撮影専用ワークフローを更新して `docs/screenshots/` に PR・Issue の簡易一覧とダッシュボード、計4枚の PNG を書き出す。Alfred の設定を同期している場合は `HUBFRED_ALFRED_WORKFLOWS` に同期先の `Alfred.alfredpreferences/workflows` を指定する。

撮影には `scripts/screenshots/fixtures.json` の合成データと UTC の固定日時を使う。撮影用の Bundle ID とキャッシュは本番から分離され、GitHub CLI には接続しない。対象ウィンドウに合成データが出ていることを確認してから、影なし・角丸の外側が透明な PNG として保存する。テーマや OS によりピクセル単位では一致しない。撮影用ワークフローとデータは正式配布物に含まれない。

撮影中だけ本番ワークフローの `pr` と `is` を退避し、撮影用ワークフローがそのキーワードで応答する。正常終了・失敗・通常の中断時に復元する。復元エラー時はコマンドがバックアップの場所を表示する。撮影中は Alfred の設定を編集しない。

## 実行時の仕様

- `pr` と `is` は Alfred のキャッシュを使う。前回の取得から30秒を過ぎて開き直すと裏で更新する。GitHub CLI のアカウントを切り替えたら Alfred で `reload` して消せる。
- `prs` と `iss` は一覧と本文を別々にローカル保存する。30秒未満なら再取得せず、30秒〜10分未満なら前回の一覧を表示して裏で更新する。更新失敗時も古い一覧は残す。初回・10分経過後・認証設定変更後は GitHub の応答を待つ。10分は表示期限で、削除期限ではない。
- 関わり方ごとに並列検索し、結果を更新日時順に表示する。GitHub Search の上限は検索条件ごとに1,000件。アイコンは [Octicons v19.19.0](https://github.com/primer/octicons/tree/v19.19.0/icons) を12色で着色する。更新日時は Mac の現地時刻で表示する。
- 本文は同梱の [Marked](https://github.com/markedjs/marked) で GFM から HTML に変換し、WebKit で表示する。生 HTML と画像は表示せず、画像はリンクとして開ける。変換プロセスが2秒でタイムアウトしても、項目は GitHub で開ける。

## CI とリリース

Dependabot の PR と `main` への push で `.alfredworkflow` を生成し、Actions の成果物としてダウンロードできる。同梱ファイルを手で更新する必要はない。

正式版は `workflow/info.plist` の `version` を更新してから、同じバージョンの `v` 付きタグを push すると GitHub Releases に公開される。タグとワークフローのバージョンが一致しない場合は公開しない。配布物には本体・Octicons・Marked のライセンスを含める。
