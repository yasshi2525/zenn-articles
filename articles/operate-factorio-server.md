---
title: "Factorioサーバーを立てて日次バックアップとゲームログイン監視をしてみた"
emoji: "👁️"
type: "tech"
topics: ["factorio", "aws", "s3", "cloudwatch", "discord"]
published: false
---

# はじめに

## 本記事の目的

友人と遊ぶ用のFactorioサーバーをAWS上に立てた。遊びの経験を損ねないようバックアップやログイン監視を頑張ったので、そのときの設定を共有する。

## やりたかったこと(Why)とやったこと(How)

* 自分が遊んでないときでも友達がいつでもログインして遊べるようにしたかったので、スタンドアロンアプリケーションであるFactorio (Headless Server) をバッググラウンド実行するようにした。
* 誤ってサーバーを消しちゃったとか誰かに荒らされた、なんてことに備えてセーブデータを日次でS3に3世代分バックアップするようにした。
* 友達とLINE等で落ち合わせなくてすむよう、友達がログインしたら自分のDiscordサーバーに通知が来るようにした。

## 想定読者

* Linuxマシンの操作経験がある
* AWS Consoleを使うことができる
* Webhookを使ったことがある

# 事前準備

本題に入る前に必要な事前作業を補足の位置づけで説明する。

## Factorioのインストール・初回起動

VPCのパブリックサブネットにEC2インスタンスを新規に作成。OSはAmazon Linux 2023を使用。
S3へのアクセス権限を持つIAMロールを作成し、EC2インスタンスに付与した。

ドメイン名で接続できるよう、Elastic IPを取得して自身が管理する独自ドメインのAレコードに設定している。

FactorioはLinux用の[Headless, for servers](https://www.factorio.com/download)を使用し、事前にワールドデータを作成している[^1]。バージョンは `2.0.47`
。Factorioのインストール方法は[公式wiki](https://wiki.factorio.com/Multiplayer#Setting_up_a_Linux_Factorio_server)を参照。以下、実行ファイル `bin/x64/factorio` にPATHが通っているものとして解説する。

[^1]: `factorio --create <ワールド名>`

# バッググラウンド実行 (デーモン化)

起動するとフォアグラウンドで実行されるため、ログアウトするとFactorioサーバーも終了してしまう。
サーバーの起動に合わせてバッググラウンドで実行されるよう Amazon Linux 2023 標準の `systemd` を使ってデーモン化する。

`/etc/systemd/system/factoriod.service`

```
[Unit]
Description=Factorio Service
After=network.target

[Service]
ExecStart=factorio --start-server <セーブファイルのパス>
# ログ監視用
StandardOutput=file:/home/ec2-user/factoriod-output.txt
Type=simple
User=ec2-user

[Install]
WantedBy=multi-user.target
```

サーバー起動に合わせて Factorioが起動するよう以下を実行

```shell
sudo systemctl enable factoriod
```

Factorioを起動するよう以下を実行

```shell
sudo systemctl start factoriod
```

起動していることを以下のコマンドで確認する。 `Active: active` となっていればOK。
```shell
sudo systemctl status factoriod
```

出力例
```
● factoriod.service - Factorio Service
     Loaded: loaded (/etc/systemd/system/factoriod.service; enabled; preset: disabled)
     Active: active (running) since Fri 2025-05-09 03:40:32 UTC; 4h 5min ago
   Main PID: 20465 (factorio)
      Tasks: 6 (limit: 1111)
     Memory: 372.8M
        CPU: 1min 7.021s
     CGroup: /system.slice/factoriod.service
             └─20465 /home/ec2-user/factorio/bin/x64/factorio --start-server /home/ec2-user/<ワールド名>.zip

May 09 03:40:32 ip-172-31-1-xxx.ap-northeast-1.compute.internal systemd[1]: Started factoriod.service - Factorio Service.
```

# セーブデータのバックアップ

Factorioはzipファイルがセーブデータなので、このファイルを毎日バックアップする。 バックアップは3日分保存するが、古いのは要らないので削除する。
`aws-cli` を使って S3 にバックアップし、S3のライフサイクルルールを使って世代管理する。

## EC2インスタンスのバックアップ設定

`cron` は Amazon Linux 2023 で非推奨になり、デフォルトで搭載されていない。推奨の `systemd timer` [^2]を使って日次実行するジョブを定義する。

[^2]: https://docs.aws.amazon.com/ja_jp/linux/al2023/ug/deprecated-al2023.html#deprecated-cron

`/etc/systemd/system/backup-factorio.service`

```
[Unit]
Description=Back up daily Factorio save data

[Service]
Type=oneshot
User=ec2-user
ExecStart=aws s3 cp <セーブファイルのパス> s3://<バケット名>

[Install]
WantedBy=multi-user.target
```

`/etc/systemd/system/backup-factorio.timer`

```
[Unit]
Description=Back up daily Factorio save data

[Timer]
OnCalendar=daily
Persistent=true
# 他のdailyジョブと実行が重複しないよう、最大10分ランダムでずらさせる
RandomizedDelaySec=10m

[Install]
WantedBy=timers.target
```

タイマーを設定するため、以下を実行

```shell
sudo systemctl start backup-factorio.timer
```

スケジュールされたことを確認するため、以下を実行。 `NEXT`, `LEFT` に値が設定されていることを確認する。

```shell
sudo systemctl list-timers backup-factorio
```

出力例 (以下はバックアップ処理実行後の結果。作成したばかりのときは `LAST` `PASSED` に値が記載されない)
```
NEXT                        LEFT     LAST                        PASSED UNIT                  ACTIVATES
Sat 2025-05-10 00:09:53 UTC 15h left Fri 2025-05-09 00:02:04 UTC 8h ago backup-factorio.timer backup-factorio.service
```


## S3のライフサイクル設定

ルールスコープを選択

- [ ] 1 つ以上のフィルターを使用してこのルールのスコープを制限する
- [x] バケット内のすべてのオブジェクトに適用

ライフサイクルルールのアクション

- [ ] 現行バージョンのオブジェクトをストレージクラス間で移行する
- [ ] 非現行バージョンのオブジェクトをストレージクラス間で移行する
- [ ] オブジェクトの現行バージョンを有効期限切れにする
- [x] オブジェクトの非現行バージョンを完全に削除
- [ ] 有効期限切れのオブジェクト削除マーカーまたは不完全なマルチパートアップロードを削除

オブジェクトの非現行バージョンを完全に削除

- オブジェクトが現行バージョンでなくなってからの日数: `1`
- 保持する新しいバージョンの数 - オプション: `2`



# ゲームへのログイン監視


