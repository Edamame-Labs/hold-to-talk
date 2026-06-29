#!/usr/bin/env python3
"""
Transcription accuracy evaluation tool.

Records your voice reading reference sentences, transcribes them via the
TranscribeCmd Swift CLI, computes WER, and saves results for iterative testing.

Modes:
  record   - Record new audio for all (or remaining) sentences
  retest   - Re-transcribe existing audio after code changes
  report   - Show results from the last run

Usage:
  python3 evaluation/evaluate.py record [-n 5]   # record first 5 sentences
  python3 evaluation/evaluate.py retest          # re-run transcription on saved audio
  python3 evaluation/evaluate.py report          # show last results
"""

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
EVALUATION_DIR = Path(__file__).resolve().parent
TEST_DIR = EVALUATION_DIR / "test_data"
REFS_FILE = TEST_DIR / "refs.txt"
RESULTS_FILE = TEST_DIR / "results.json"

SENTENCES = [
    "The quick brown fox jumps over the lazy dog.",
    "Hello, my name is Kevin and I live in San Francisco.",
    "Can you please send me the quarterly report by Friday?",
    "The meeting starts at three thirty in conference room B.",
    "I think we should refactor the authentication module first.",
    "She ordered a large coffee with oat milk and no sugar.",
    "The temperature outside is seventy two degrees Fahrenheit.",
    "Please remind me to call the dentist tomorrow morning.",
    "We need to deploy the hotfix to production before midnight.",
    "The restaurant on Fifth Avenue has excellent pasta.",
    "I am going to the grocery store to buy eggs and bread.",
    "Machine learning models require large amounts of training data.",
    "Turn left at the next intersection and then go straight.",
    "The annual budget review is scheduled for next Wednesday.",
    "Python is a popular programming language for data science.",
    "Could you pick up the kids from school at four o'clock?",
    "The new feature reduces latency by approximately forty percent.",
    "It is raining outside so do not forget your umbrella.",
    "The board approved the merger with a unanimous vote.",
    "Open the terminal and run the build command.",
]


def normalize(text):
    """Lowercase, strip punctuation, collapse whitespace."""
    text = text.lower().strip()
    text = re.sub(r"[^\w\s]", "", text)
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def wer(ref, hyp):
    """Compute word error rate using dynamic programming."""
    r = normalize(ref).split()
    h = normalize(hyp).split()
    d = [[0] * (len(h) + 1) for _ in range(len(r) + 1)]
    for i in range(len(r) + 1):
        d[i][0] = i
    for j in range(len(h) + 1):
        d[0][j] = j
    for i in range(1, len(r) + 1):
        for j in range(1, len(h) + 1):
            if r[i - 1] == h[j - 1]:
                d[i][j] = d[i - 1][j - 1]
            else:
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + 1)
    return d[len(r)][len(h)], len(r)


def build_transcribe_cmd():
    """Build the TranscribeCmd target."""
    print("Building TranscribeCmd...", flush=True)
    result = subprocess.run(
        ["swift", "build", "--target", "TranscribeCmd"],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"Build failed:\n{result.stderr}", file=sys.stderr)
        sys.exit(1)
    # Find the binary
    find = subprocess.run(
        ["swift", "build", "--target", "TranscribeCmd", "--show-bin-path"],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
    )
    bin_path = Path(find.stdout.strip()) / "TranscribeCmd"
    return bin_path


def transcribe_wav(cmd_path, wav_path, verbose=False):
    """Run TranscribeCmd on a WAV file and return the transcription."""
    args = [str(cmd_path), str(wav_path)]
    if verbose:
        args.append("-v")
    result = subprocess.run(args, capture_output=True, text=True, cwd=PROJECT_ROOT)
    if result.returncode != 0:
        print(f"  Error transcribing {wav_path}: {result.stderr}", file=sys.stderr)
        return ""
    return result.stdout.strip()


def record_wav(output_path, sentence_num, total):
    """Record audio from microphone using ffmpeg."""
    print(f"\n[{sentence_num}/{total}] Press ENTER to start recording, then ENTER to stop.")
    input("  > ")

    # Use ffmpeg to record from default mic
    proc = subprocess.Popen(
        [
            "ffmpeg",
            "-y",
            "-f",
            "avfoundation",
            "-i",
            ":default",
            "-ar",
            "16000",
            "-ac",
            "1",
            str(output_path),
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    print("  Recording... press ENTER to stop.", flush=True)
    input()

    # Send 'q' to ffmpeg to stop gracefully
    proc.communicate(input=b"q")
    time.sleep(0.2)

    if not output_path.exists() or output_path.stat().st_size < 100:
        print(f"  Warning: recording may have failed for {output_path}")
        return False
    return True


def wav_path_for(idx):
    return TEST_DIR / f"sentence_{idx + 1:02d}.wav"


def do_record(num_sentences=None, verbose=False):
    """Record audio for reference sentences."""
    TEST_DIR.mkdir(parents=True, exist_ok=True)
    cmd_path = build_transcribe_cmd()

    n = num_sentences or len(SENTENCES)
    n = min(n, len(SENTENCES))

    results = []
    total_errors = 0
    total_words = 0

    print(f"\n{'=' * 60}")
    print("TRANSCRIPTION ACCURACY TEST")
    print(f"{'=' * 60}")
    print(f"Recording {n} sentences. Read each sentence clearly.\n")

    for i in range(n):
        ref = SENTENCES[i]
        wav = wav_path_for(i)

        print(f"  REF: {ref}")

        if wav.exists():
            answer = input(f"  Audio exists ({wav.name}). Re-record? [y/N/skip/quit]: ").strip().lower()
            if answer == "quit":
                break
            if answer == "skip":
                # Transcribe existing
                hyp = transcribe_wav(cmd_path, wav, verbose)
                errors, words = wer(ref, hyp)
                total_errors += errors
                total_words += words
                rate = errors / words * 100 if words > 0 else 0
                status = "PERFECT" if errors == 0 else f"WER {rate:.0f}% ({errors}/{words})"
                print(f"  HYP: {hyp}")
                print(f"  --> {status}")
                results.append(
                    {"idx": i + 1, "ref": ref, "hyp": hyp, "wer": rate, "errors": errors, "words": words,
                     "file": str(wav.name)}
                )
                continue
            if answer != "y":
                # Use existing recording
                hyp = transcribe_wav(cmd_path, wav, verbose)
                errors, words = wer(ref, hyp)
                total_errors += errors
                total_words += words
                rate = errors / words * 100 if words > 0 else 0
                status = "PERFECT" if errors == 0 else f"WER {rate:.0f}% ({errors}/{words})"
                print(f"  HYP: {hyp}")
                print(f"  --> {status}")
                results.append(
                    {"idx": i + 1, "ref": ref, "hyp": hyp, "wer": rate, "errors": errors, "words": words,
                     "file": str(wav.name)}
                )
                continue

        if not record_wav(wav, i + 1, n):
            continue

        hyp = transcribe_wav(cmd_path, wav, verbose)
        errors, words = wer(ref, hyp)
        total_errors += errors
        total_words += words
        rate = errors / words * 100 if words > 0 else 0
        status = "PERFECT" if errors == 0 else f"WER {rate:.0f}% ({errors}/{words})"

        print(f"  HYP: {hyp}")
        print(f"  --> {status}")

        results.append(
            {"idx": i + 1, "ref": ref, "hyp": hyp, "wer": rate, "errors": errors, "words": words,
             "file": str(wav.name)}
        )

    print_summary(results, total_errors, total_words)
    save_results(results)


def do_retest(verbose=False):
    """Re-transcribe existing audio files after code changes."""
    cmd_path = build_transcribe_cmd()

    wav_files = sorted(TEST_DIR.glob("sentence_*.wav"))
    if not wav_files:
        print("No audio files found in evaluation/test_data/. Run 'record' first.", file=sys.stderr)
        sys.exit(1)

    results = []
    total_errors = 0
    total_words = 0

    print(f"\n{'=' * 60}")
    print("RE-TESTING TRANSCRIPTION (existing audio)")
    print(f"{'=' * 60}\n")

    for wav in wav_files:
        # Extract index from filename
        match = re.match(r"sentence_(\d+)\.wav", wav.name)
        if not match:
            continue
        idx = int(match.group(1)) - 1
        if idx >= len(SENTENCES):
            continue

        ref = SENTENCES[idx]
        hyp = transcribe_wav(cmd_path, wav, verbose)
        errors, words = wer(ref, hyp)
        total_errors += errors
        total_words += words
        rate = errors / words * 100 if words > 0 else 0
        status = "PERFECT" if errors == 0 else f"WER {rate:.0f}% ({errors}/{words})"

        print(f"[{idx + 1:2d}] {status}")
        if errors > 0:
            print(f"     REF: {ref}")
            print(f"     HYP: {hyp}")

        results.append(
            {"idx": idx + 1, "ref": ref, "hyp": hyp, "wer": rate, "errors": errors, "words": words,
             "file": str(wav.name)}
        )

    print_summary(results, total_errors, total_words)
    save_results(results)


def do_report():
    """Show results from the last run."""
    if not RESULTS_FILE.exists():
        print("No results found. Run 'record' or 'retest' first.", file=sys.stderr)
        sys.exit(1)

    with open(RESULTS_FILE) as f:
        results = json.load(f)

    total_errors = sum(r["errors"] for r in results)
    total_words = sum(r["words"] for r in results)

    print(f"\n{'=' * 60}")
    print("LAST RESULTS")
    print(f"{'=' * 60}\n")

    for r in results:
        status = "PERFECT" if r["errors"] == 0 else f"WER {r['wer']:.0f}% ({r['errors']}/{r['words']})"
        print(f"[{r['idx']:2d}] {status}")
        if r["errors"] > 0:
            print(f"     REF: {r['ref']}")
            print(f"     HYP: {r['hyp']}")

    print_summary(results, total_errors, total_words)


def print_summary(results, total_errors, total_words):
    """Print summary statistics."""
    if not results:
        return

    print(f"\n{'=' * 60}")
    print("SUMMARY")
    print(f"{'=' * 60}")

    if total_words > 0:
        overall = total_errors / total_words * 100
        perfect = sum(1 for r in results if r["errors"] == 0)
        tested = len(results)
        print(f"  Overall WER: {overall:.1f}% ({total_errors} errors / {total_words} words)")
        print(f"  Perfect:     {perfect}/{tested} sentences")
        print(f"  Tested:      {tested}/{len(SENTENCES)} sentences")

    # Show worst sentences
    worst = sorted(results, key=lambda r: r["wer"], reverse=True)[:3]
    if worst and worst[0]["errors"] > 0:
        print(f"\n  Worst sentences:")
        for r in worst:
            if r["errors"] == 0:
                break
            print(f"    [{r['idx']:2d}] WER {r['wer']:.0f}%: \"{r['hyp']}\"")


def save_results(results):
    """Save results to JSON."""
    with open(RESULTS_FILE, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nResults saved to {RESULTS_FILE}")
    print(f"\nTo re-test after code changes:")
    print(f"  python3 evaluation/evaluate.py retest")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 evaluation/evaluate.py <record|retest|report> [-v] [-n NUM]")
        sys.exit(1)

    mode = sys.argv[1]
    verbose = "-v" in sys.argv
    num = None
    for i, arg in enumerate(sys.argv):
        if arg == "-n" and i + 1 < len(sys.argv):
            num = int(sys.argv[i + 1])

    if mode == "record":
        do_record(num_sentences=num, verbose=verbose)
    elif mode == "retest":
        do_retest(verbose=verbose)
    elif mode == "report":
        do_report()
    else:
        print(f"Unknown mode: {mode}")
        print("Usage: python3 evaluation/evaluate.py <record|retest|report> [-v] [-n NUM]")
        sys.exit(1)
