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
また、やりたいことをブレークダウンしてクラウドサービスを活用していく過程を示すことで、クラウドサービスを使いこなすためのヒントが提供できればとも思っている。

## やりたかったこと(Why)とやったこと(How)

* 自分が遊んでないときでも友達がいつでもログインして遊べるようにしたかったので、スタンドアロンアプリケーションであるFactorio (Headless Server) をバッググラウンド実行するようにした。
* 誤ってサーバーを消してしまったとか誰かに荒らされた、なんてことに備えてセーブデータを日次でS3に3世代分バックアップするようにした。
* 友達とLINE等で落ち合わせなくてすむよう、友達がログインしたら自分のDiscordサーバーに通知が来るようにした。

## 想定読者

* Linuxマシンの操作経験がある
* AWS Consoleを使うことができる
* Webhookを使ったことがある

# 事前準備

本題に入る前に必要な事前作業を補足の位置づけで説明する。

## Factorioのインストール・初回起動

VPCのパブリックサブネットにEC2インスタンスを新規に作成。OSはAmazon Linux 2023を使用。

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
`aws-cli` を使って S3 にバックアップし、S3のライフサイクルルールを使って世代管理する。S3 にファイル送信できるようにするため、EC2インスタンスにはS3への書き込み権限を持つIAMロールの付与が必要。

## EC2インスタンスのバックアップ設定

`cron` は Amazon Linux 2023 で非推奨になり、デフォルトで搭載されていない。推奨の `systemd timer` [^2]を使って日次実行するジョブを定義する。
また、上記にも記載した通りS3への書き込み権限を持つIAMロールを作成して、EC2インスタンスに付与する。

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

## 監視方法の検討

Factorio headless serverではプレイヤーがゲームにログインすると、標準出力に下記のようなメッセージが出力される(`2.0.47`時点)。`******` はプレイヤーID。

```
2025-05-09 09:40:32 [JOIN] ****** joined the game
```

そこで、Factorioサーバーの標準出力を監視し、上記のようなパターンに合致するメッセージが出力されたら、手元に通知されるような仕組みを考えた。Factorioサーバーの標準出力を(監視が平易な)ファイルに出力させるようにし、Cloud Watch Agentにそのファイルを監視させた。ログはCloudWatch Logsに集約し、

## CloudWatch Logsの監視設定

CloudWatch Logsのロググループを作成する。

ロググループにサブスクリプションフィルタを作成する。今回は少量のログデータの監視と簡易な通知処理のためLambdaサブスクリプションフィルターを作成した。

### Lambda関数の作成

関数の作成

- [x] 一から作成
- [ ] 設計図の使用
- [ ] コンテナイメージ

基本的な情報

- 関数名: `NotifyFactorioLogin`
- ランタイム: `Node.js 18.x`
- アーキテクチャ: 
  - [x] x86_64
  - [ ] arm64

環境変数 `targetUrl` には 取得した Discord の Webhook URL を指定している。 [取得方法の解説](https://discordjs.guide/popular-topics/webhooks.html#creating-webhooks-through-server-settings)

```javascript
import * as zlib from 'node:zlib';

/**
 * CloudWatch LogsがLambdaに渡すイベントデータの形式
 * @typedef {Object} CloudWatchLogsEvent
 * @property {string} messageType メッセージタイプ。DATA_MESSAGE固定
 * @property {string} owner ログデータを発行した AWS アカウント ID。
 * @property {string} logGroup ロググループ名
 * @property {string} logStream ログストリーミング名
 * @property {string[]} subscriptionFilters 適用されているサブスクリプションフィルタのリスト
 * @property {LogEvent[]} logEvents ログデータ本体
 */

/**
 * ログイベント。1つのログイベントを表す。
 * @typedef {Object} LogEvent
 * @property {string} id ログを一意に指すID
 * @property {number} timestamp ログの発生時刻。UNIX時間。
 * @property {string} message メッセージ本文
 */

/**
 * @param {string} event.awslogs.data データ本文をzip形式で圧縮し、更にbase64でエンコードした値
 */
export const handler = async (event) => {
    // CloudWatchから渡されたイベントデータの取得
    /** @type {CloudWatchLogsEvent} */
    const data = JSON.parse(zlib.gunzipSync(Buffer.from(event.awslogs.data, 'base64')).toString());

    // Discordに通知するメッセージを作成
    const content = data.logEvents.map(e => `\`${e.message}\``).join('\n')

    // DiscordのWebhookにPOST
    const res = await fetch(process.env.targetUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ content })
    })
    if (!res.ok) {
        throw new Error(`HTTP error! status: ${res.status}, body: ${JSON.stringify(res.body())}`);
    }
};
```

サンプルイベントデータ
```json
{
  "awslogs": {
    "data": "H4sIAAAAAAAAA0VPUYuCQBB+v1+xzHOBpmVKHAhnUlA92FvIYuect4fuyu5aRPTfG70kmIdvvm++b2bu0KAxRYXHW4sQwVd8jPkuybI4TWAC6ipRE70aABflJ5G1qlKturbnCfOqb7gsGnypmdVYNKNshu7lNd3ZfGvRWqHkWtQWtYHoBD8DZH9KSCwZuSAfkpILSttP3EGUY+B/khV0uS0aOsMN/EUQOkHgh/5yMn5E4zNnNp86VCFz3cgLI89lp+1hs8+ZIWeNvDPvtfYXWUVfwCN/fDwBbUn1JxkBAAA="
  }
}
```

サンプル実行結果

![](/images/operate_factorio_server_discord_screenshot.png)

### Lambdaサブスクリプションフィルタの作成

CloudWatch Logsのサブスクリプションフィルタを作成する。

- Lambda関数: `NotifyFactorioLogin`
- ログ形式とフィルターを設定
  - ログの形式: `その他`
  - サブスクリプションフィルタのパターン: `% \[JOIN\] \w* joined the game%`
  - サブスクリプションフィルター名: `filter joined log`

以下のデータでパターンをテストし、プレイヤーIDがログインしたメッセージを抽出できるか確認する。

- パターンをテスト
  - テストするログデータを選択: `カスタムログデータ`
  - イベントメッセージをログ記録: `2025-05-09 09:40:32 [JOIN] sample_user joined the game`

問題がなければストリーミングを開始する。

## EC2インスタンスのログ監視設定

今度はログインメッセージを含むログ情報を監視して、CloudWatch Logsに送信するよう設定する。

### 標準出力のファイル出力

今回、監視したい対象はFactorioサーバーの標準出力なので、まず一般に監視しやすい形式であるファイルとして出力されるようにする。

`/etc/systemd/system/factoriod.service`

```
[Service]
# 下記を追加
StandardOutput=append:/var/log/factoriod-output.txt
```

### CloudWatch Agentによるログ収集

EC2インスタンスにアタッチしているIAMロールの許可ポリシーに`CloudWatchAgentServerPolicy` を追加しておく必要がある

EC2インスタンスに`cloudwatch-agent`をインストール。

```shell
sudo dnf install amazon-cloudwatch-agent 
```

CloudWatch Agent の設定ファイルを記述する。
Factorioプロセスの標準出力が出力されたログファイル `/var/log/factoriod-output.txt` を収集する。なお、下記ファイルは`amazon-cloudwatch-agent-config-wizard` ([解説](https://docs.aws.amazon.com/ja_jp/AmazonCloudWatch/latest/monitoring/create-cloudwatch-agent-configuration-file-wizard.html))を使って作成した。

`/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json`

```json
{
  "agent": {
    "run_as_user": "cwagent"
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/factoriod-output.txt",
            "log_group_class": "STANDARD",
            "log_group_name": "<ロググループ名>",
            "log_stream_name": "{instance_id}",
            "retention_in_days": 7
          }
        ]
      }
    }
  }
}
```

CloudWatch Agent を起動する。

```shell
sudo systemctl enable amazon-cloudwatch-agent
sudo systemctl start amazon-cloudwatch-agent
```

CloudWatch Agent が起動したことを確認する。 `Active: active` となっていればOK。

```shell
sudo systemctl status amazon-cloudwatch-agent
```

出力例
```
● amazon-cloudwatch-agent.service - Amazon CloudWatch Agent
     Loaded: loaded (/etc/systemd/system/amazon-cloudwatch-agent.service; enabled; preset: disabled)
     Active: active (running) since Fri 2025-05-09 09:33:44 UTC; 2min 1s ago
   Main PID: 33595 (amazon-cloudwat)
      Tasks: 7 (limit: 1111)
     Memory: 131.5M
        CPU: 434ms
     CGroup: /system.slice/amazon-cloudwatch-agent.service
             └─33595 /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent -config /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.toml -envconfig /opt/aws/amazon-cloudwatch-agent/etc/env-config.json -otelconfig /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.yaml -pidfile /opt/aws/amazon-cloudwatch-agent/var/amazon-cloudwatch-agent.pid

May 09 09:33:44 ip-172-31-1-xxx.ap-northeast-1.compute.internal systemd[1]: Started amazon-cloudwatch-agent.service - Amazon CloudWatch Agent.
May 09 09:33:45 ip-172-31-1-xxx.ap-northeast-1.compute.internal start-amazon-cloudwatch-agent[33599]: D! [EC2] Found active network interface
May 09 09:33:45 ip-172-31-1-xxx.ap-northeast-1.compute.internal start-amazon-cloudwatch-agent[33599]: I! imds retry client will retry 1 timesI! Detected the instance is EC2
May 09 09:33:45 ip-172-31-1-xxx.ap-northeast-1.compute.internal start-amazon-cloudwatch-agent[33599]: 2025/05/09 09:33:45 Reading json config file path: /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json ...
May 09 09:33:45 ip-172-31-1-xxx.ap-northeast-1.compute.internal start-amazon-cloudwatch-agent[33599]: 2025/05/09 09:33:45 I! Valid Json input schema.
May 09 09:33:45 ip-172-31-1-xxx.ap-northeast-1.compute.internal start-amazon-cloudwatch-agent[33599]: I! Detecting run_as_user...
May 09 09:33:45 ip-172-31-1-xxx.ap-northeast-1.compute.internal start-amazon-cloudwatch-agent[33599]: I! Trying to detect region from ec2
May 09 09:33:45 ip-172-31-1-xxx.ap-northeast-1.compute.internal start-amazon-cloudwatch-agent[33599]: 2025/05/09 09:33:45 Configuration validation first phase succeeded
May 09 09:33:45 ip-172-31-1-xxx.ap-northeast-1.compute.internal start-amazon-cloudwatch-agent[33595]: I! Detecting run_as_user...
```

# まとめ

友達とFactorioを遊びたい。という動機からAWSのEC2インスタンスを立てた。
Factorioはフォアグラウンドアプリケーションだったので、自分が接続していないときでも常時遊べるよう、まずはFactorioをsystemdでデーモン化した。
次に、セーブデータがもし消えるととても悲しいことになるので、S3にバックアップをとるようにした。古いバックアップは要らないのでライフサイクルルールで自動で削除されるようにした。
最後に、友達がログインしたことに気がつけるよう次のように考えた。Factorioは誰かがログインすると標準出力にメッセージを出すので、これをどうにかして気がつけないか考えた。まずは監視が平易になるようsystemdの機能を使ってファイルとして出力させた。次にCloudWatch Agentを使ってそのファイルの更新内容をつねにCloudWatch Logsに送るようにした。そしてCloudWatch Logsのサブスクリプションフィルタを使って、ログインに該当するメッセージがあったか判定し、Lambda関数を実行するようにした。Lambda関数の中でDiscordのWebhookのURLを呼び出すようにしたことで、友達がログインしたことを自身のDiscordサーバーに通知するようにした。

## おわりに

「何かしたい→どう実現するか→今度はこうしたい」というサイクルを繰り返すことで、友達と楽しく遊ぶという最終目標を短期間で実現できました。クラウドサービスは便利で色々なことができますが、全部覚えようとするよりも、やりたいことの実現手段として使ってみることが、使いこなすコツだと思います。今回の私の実現手順が、クラウドサービスをどう活用しようか考える一助になれば幸いです。
