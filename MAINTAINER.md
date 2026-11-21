# メンテナ向けガイド

## ローカル開発

リポジトリのルートで Node.js 24、npm、`zip` を使ってビルドする。`npm ci` は初回とロックファイルが変わったときに実行する。

```bash
npm ci --ignore-scripts
npm run package
open dist/Hubfred.alfredworkflow
```

`npm run package` は Git インデックスにある `workflow/` のファイルを作業ツリーから読み取るため、既存ファイルの未コミット変更も含む。追加したファイルは先に Git の追跡対象にする。Marked の JavaScript とライセンスはロック済み npm 配布物からパッケージにだけ同梱する。

## CI とリリース

Dependabot の PR と `main` への push で `.alfredworkflow` を生成し、Actions の成果物としてダウンロードできる。同梱ファイルを手で更新する必要はない。

正式版は `workflow/info.plist` の `version` を更新してから、同じバージョンの `v` 付きタグを push すると GitHub Releases に公開される。タグとワークフローのバージョンが一致しない場合は公開しない。配布物には本体・Octicons・Marked のライセンスを含める。
