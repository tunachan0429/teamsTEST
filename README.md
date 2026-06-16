# DOGE POWER CONTROL — iOS App
GitHub Actions（macOSランナー）でビルド → AltStoreで実機にサイドロードする構成です。
Mac実機は不要、証明書(.p12)やプロビジョニングプロファイルの手動準備も不要です。

---

## 仕組み

```
push する
  → GitHub Actions が macOS ランナー上で xcodebuild 実行
  → 署名なし(unsigned) の .ipa を生成
  → Artifacts からダウンロード
  → AltStore / AltServer で実機にインストール（端末側で自動署名される）
```

---

## セットアップ手順

### STEP 1. tunachan0429/teamsTEST リポジトリを入れ替える

既存ファイル（Pythonのteams-discordブリッジ関連）をすべて削除し、
このフォルダの中身をそのまま push してください。

```bash
git clone https://github.com/tunachan0429/teamsTEST.git
cd teamsTEST

# 既存ファイルを削除
git rm -r --cached .
rm -rf gitignore railway.toml requirements.txt teams_discord_webhook_bridge.py

# 今回のXcodeプロジェクト一式をこのフォルダにコピー
# (DogePowerControl/, DogePowerControl.xcodeproj/, .github/, .gitignore, README.md)

git add .
git commit -m "Replace with DogePowerControl iOS app"
git push origin main
```

### STEP 2. GitHub Actions の実行を確認

1. リポジトリの **Actions** タブを開く
2. `Build Unsigned IPA (AltStore)` ワークフローが自動で走る（pushで自動トリガー）
3. 数分待つとビルドが完了し、緑のチェックが付く
4. 完了したワークフロー実行をクリック → 一番下の **Artifacts** に
   `DogePowerControl-unsigned-ipa` がある → クリックしてダウンロード（zip）

### STEP 3. .ipa を取り出す

ダウンロードしたzipを展開すると `DogePowerControl-unsigned.ipa` が出てきます。

### STEP 4. AltStore でインストール

1. iPhone/iPadで **AltStore** アプリを開く（または PC側でAltServer経由）
2. **My Apps** タブ → 左上の **+** ボタン
3. ダウンロードした `DogePowerControl-unsigned.ipa` を選択
4. Apple IDでサインインを求められたら入力 → インストール完了
5. ホーム画面にアプリが追加される

> 注意: AltStoreの無料Apple ID署名は **7日間で期限切れ** になります。
> AltServerをPCで起動しておけば自動で再署名されますが、
> されない場合はAltStoreアプリ内で「Refresh」を実行してください。

---

## アプリの機能設定（⚙ボタン）

インストール後、アプリ右上の歯車アイコンから以下を設定:

| 項目 | 説明 | 例 |
|---|---|---|
| MAC ADDRESS | 起動したいPCのMACアドレス | `AA:BB:CC:DD:EE:FF` |
| BROADCAST | サブネットのブロードキャストIP | `192.168.1.255` |
| HOST IP | PCのIPアドレス | `192.168.1.10` |
| SSH PORT | SSHポート（通常22） | `22` |
| USERNAME | Windowsのユーザー名 | `username` |
| PASSWORD | Windowsのログインパスワード | `••••••••` |

### 動作の流れ
- **POWER ON** → Wake-on-LANパケット送信 → PCが応答するまで最大60秒ポーリング → ONLINE表示
- **POWER OFF** → SSH接続 → `shutdown /s /t 0` 実行 → オフラインになるまでポーリング

---

## PC側の事前設定

### Wake-on-LAN を有効化（電源ONに必要）
- BIOS/UEFIで **Wake on LAN** を有効化
- Windows: デバイスマネージャー → ネットワークアダプター → プロパティ →
  「電源の管理」タブ →「このデバイスで、コンピューターのスタンバイ状態を解除できるようにする」にチェック

### OpenSSH Server をインストール（電源OFFに必要）
```powershell
設定 → アプリ → オプション機能 → 「OpenSSH サーバー」を追加

# サービスを自動起動に設定
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
```
Windows Firewallで **ポート22** を許可してください。

> 重要: iPhone（外出先）からPCに接続するには、自宅ルーターのポート開放（ポートフォワーディング）
> または同一Wi-Fi内での利用が必要です。外部からアクセスする場合はVPN等の利用を推奨します。

---

## ファイル構成

```
.github/workflows/build-ipa.yml   ← GitHub Actions ビルド設定
DogePowerControl.xcodeproj/
DogePowerControl/
├── DogePowerControlApp.swift
├── ContentView.swift              ← WoL・SSH(Citadel)・UI 全部ここ
├── Info.plist
└── Assets.xcassets/
    ├── img_doge.imageset/
    ├── img_on.imageset/
    └── img_off.imageset/
```

## 使用ライブラリ
- **Citadel** (https://github.com/orlandos-nl/Citadel) — 純Swift製SSHクライアント。
  CocoaPods/Objective-C依存がないため、署名なしCIビルドでも安定して解決できます。

## トラブルシューティング

### Actions のビルドが `SSHClient.connect` の引数エラーで失敗する場合
Citadelのバージョンによって `connect` の引数名が異なることがあります。
`ContentView.swift` 内の `SSHService.shutdown` を以下のように書き換えてください:

```swift
let settings = SSHClientSettings(
    host: host,
    port: port,
    authenticationMethod: { .passwordBased(username: username, password: password) },
    hostKeyValidator: .acceptAnything()
)
let client = try await SSHClient.connect(to: settings)
```

### Wake-on-LANが届かない
- iPhoneとPCが同一Wi-Fi/LAN内にあることを確認
- ルーターが UDP ブロードキャストをブロックしていないか確認
- 一部のルーターはブロードキャストではなく `192.168.1.255` のような
  サブネット指定アドレスでないと通さないことがあるため、設定画面の
  BROADCASTを実際のサブネットに合わせて変更してください

### SSH接続が失敗する
- Windows Defender ファイアウォールでポート22がブロックされていないか確認
- `Get-Service sshd` で OpenSSH サービスが running か確認
