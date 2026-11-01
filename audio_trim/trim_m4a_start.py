#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
trim_m4a_start.py

このスクリプトと同じフォルダにある .m4a ファイルすべてに対して、
指定した秒数だけ先頭を削除(トリミング)します。

事前準備:
    ffmpeg をインストールし、コマンドラインから `ffmpeg` が実行できる状態にしておいてください。
    - Windows: https://www.gyan.dev/ffmpeg/builds/ からダウンロードし、PATHを通す
    - macOS  : brew install ffmpeg
    - Linux  : sudo apt install ffmpeg など

使い方:
    python trim_m4a_start.py 5
        → 先頭5秒をカットする

    python trim_m4a_start.py 3.5 --reencode
        → 先頭3.5秒をカットする(再エンコードして正確にカットしたい場合)

    python trim_m4a_start.py 5 --outdir trimmed
        → 元ファイルを上書きせず、"trimmed" フォルダに出力する

デフォルトの挙動:
    - 元ファイルは上書きされます(実行前にバックアップを推奨します)
    - デフォルトは -c copy (無劣化・高速) でカットします。
      ただし -c copy はキーフレーム/フレーム境界の都合でカット位置が
      数十ミリ秒前後ずれることがあります。厳密な位置でカットしたい場合は
      --reencode オプションを付けてください(処理は遅くなりますが正確です)。
"""

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


def check_ffmpeg():
    if shutil.which("ffmpeg") is None:
        print("エラー: ffmpeg が見つかりません。インストールしてPATHを通してください。", file=sys.stderr)
        sys.exit(1)


def trim_file(src: Path, seconds: float, dst: Path, reencode: bool):
    """1つのm4aファイルを先頭からseconds秒トリミングしてdstに出力する"""
    tmp_out = dst.with_suffix(dst.suffix + ".tmp.m4a")

    cmd = ["ffmpeg", "-y", "-ss", str(seconds), "-i", str(src)]

    if reencode:
        # 再エンコードして正確な位置でカット
        cmd += ["-c:a", "aac", "-b:a", "192k"]
    else:
        # 再エンコードなし(高速・無劣化だがカット位置が多少前後する場合あり)
        cmd += ["-c", "copy"]

    cmd += [str(tmp_out)]

    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    if result.returncode != 0:
        print(f"  失敗: {src.name}")
        print(result.stderr.decode(errors="ignore"))
        if tmp_out.exists():
            tmp_out.unlink()
        return False

    # 一時ファイルを最終的な出力先に移動(上書きの場合は元ファイルを置き換える)
    shutil.move(str(tmp_out), str(dst))
    return True


def main():
    parser = argparse.ArgumentParser(description="フォルダ内のm4aファイルの先頭を指定秒数トリミングする")
    parser.add_argument("seconds", type=float, help="先頭から削除する秒数(例: 5 や 3.5)")
    parser.add_argument(
        "--outdir",
        type=str,
        default=None,
        help="出力先フォルダ名(指定しない場合は元ファイルを上書きします)",
    )
    parser.add_argument(
        "--reencode",
        action="store_true",
        help="正確な位置でカットしたい場合に指定(再エンコードするため処理は遅くなります)",
    )
    args = parser.parse_args()

    if args.seconds < 0:
        print("エラー: 秒数は0以上を指定してください。", file=sys.stderr)
        sys.exit(1)

    check_ffmpeg()

    script_dir = Path(__file__).resolve().parent
    m4a_files = sorted(script_dir.glob("*.m4a"))

    if not m4a_files:
        print("m4aファイルが見つかりませんでした。スクリプトと同じフォルダに置いてください。")
        return

    if args.outdir:
        out_dir = script_dir / args.outdir
        out_dir.mkdir(exist_ok=True)
    else:
        out_dir = None  # 上書きモード

    print(f"{len(m4a_files)} 件のm4aファイルを処理します(先頭 {args.seconds} 秒を削除)...\n")

    success_count = 0
    for f in m4a_files:
        dst = (out_dir / f.name) if out_dir else f
        print(f"処理中: {f.name}")
        if trim_file(f, args.seconds, dst, args.reencode):
            success_count += 1
            print("  完了")
        print()

    print(f"完了しました: {success_count}/{len(m4a_files)} 件成功")


if __name__ == "__main__":
    main()
