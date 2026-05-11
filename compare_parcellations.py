#!/usr/bin/env python3
"""Compare two HCP-MMP1 parcellation volumes."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def import_dependencies():
    try:
        import nibabel as nib
        import numpy as np
    except ImportError as error:
        raise SystemExit(
            "This comparison script needs nibabel and numpy. Install them with "
            "conda or pip, then rerun the validation."
        ) from error

    return nib, np


def load_labels(path: Path):
    nib, np = import_dependencies()
    image = nib.load(str(path))
    data = np.asanyarray(image.dataobj)

    if np.issubdtype(data.dtype, np.floating):
        rounded = np.rint(data)
        if not np.allclose(data, rounded, atol=1e-6, rtol=0):
            raise SystemExit(f"{path} contains non-integer label values.")
        data = rounded.astype(np.int64)
    else:
        data = data.astype(np.int64, copy=False)

    return image, data


def label_counts(np, data):
    values, counts = np.unique(data, return_counts=True)
    return {int(value): int(count) for value, count in zip(values, counts)}


def build_result(reference_path: Path, candidate_path: Path, affine_tolerance: float):
    _, np = import_dependencies()
    reference_image, reference = load_labels(reference_path)
    candidate_image, candidate = load_labels(candidate_path)

    shape_match = reference.shape == candidate.shape
    affine_delta = float(np.max(np.abs(reference_image.affine - candidate_image.affine)))
    affine_match = affine_delta <= affine_tolerance

    differing_voxels = None
    differing_fraction = None
    changed_pairs: list[dict[str, int]] = []

    if shape_match:
        difference_mask = reference != candidate
        differing_voxels = int(np.count_nonzero(difference_mask))
        differing_fraction = float(differing_voxels / reference.size) if reference.size else 0.0

        if differing_voxels:
            pair_values, pair_counts = np.unique(
                np.column_stack((reference[difference_mask], candidate[difference_mask])),
                axis=0,
                return_counts=True,
            )
            sorted_pairs = sorted(
                zip(pair_values, pair_counts),
                key=lambda item: int(item[1]),
                reverse=True,
            )
            changed_pairs = [
                {
                    "reference_label": int(pair[0]),
                    "candidate_label": int(pair[1]),
                    "voxels": int(count),
                }
                for pair, count in sorted_pairs[:20]
            ]

    reference_counts = label_counts(np, reference)
    candidate_counts = label_counts(np, candidate)
    labels = sorted(set(reference_counts) | set(candidate_counts))
    label_deltas = [
        {
            "label": label,
            "reference_voxels": reference_counts.get(label, 0),
            "candidate_voxels": candidate_counts.get(label, 0),
            "delta": candidate_counts.get(label, 0) - reference_counts.get(label, 0),
        }
        for label in labels
        if reference_counts.get(label, 0) != candidate_counts.get(label, 0)
    ]

    return {
        "reference": str(reference_path),
        "candidate": str(candidate_path),
        "shape_match": shape_match,
        "reference_shape": list(reference.shape),
        "candidate_shape": list(candidate.shape),
        "affine_match": affine_match,
        "affine_max_abs_delta": affine_delta,
        "differing_voxels": differing_voxels,
        "differing_fraction": differing_fraction,
        "label_count_differences": label_deltas,
        "top_changed_label_pairs": changed_pairs,
    }


def write_tsv(path: Path, result: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        handle.write("label\treference_voxels\tcandidate_voxels\tdelta\n")
        for row in result["label_count_differences"]:
            handle.write(
                f"{row['label']}\t{row['reference_voxels']}\t"
                f"{row['candidate_voxels']}\t{row['delta']}\n"
            )


def print_summary(result: dict) -> None:
    print(f"Reference: {result['reference']}")
    print(f"Candidate: {result['candidate']}")
    print(f"Shape match: {result['shape_match']}")
    print(f"Affine match: {result['affine_match']}")
    print(f"Affine max abs delta: {result['affine_max_abs_delta']:.8g}")

    if result["differing_voxels"] is None:
        print("Voxel comparison: skipped because shapes differ")
        return

    percent = result["differing_fraction"] * 100
    print(f"Differing voxels: {result['differing_voxels']} ({percent:.6f}%)")

    if result["label_count_differences"]:
        print("Labels with count differences:")
        for row in result["label_count_differences"][:20]:
            print(
                f"  {row['label']}: reference={row['reference_voxels']} "
                f"candidate={row['candidate_voxels']} delta={row['delta']}"
            )

    if result["top_changed_label_pairs"]:
        print("Most common changed label pairs:")
        for row in result["top_changed_label_pairs"][:10]:
            print(
                f"  {row['reference_label']} -> {row['candidate_label']}: "
                f"{row['voxels']} voxels"
            )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Compare two HCP-MMP1 NIfTI parcellation volumes."
    )
    parser.add_argument("reference", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--json-out", type=Path)
    parser.add_argument("--tsv-out", type=Path)
    parser.add_argument("--affine-tolerance", type=float, default=1e-5)
    parser.add_argument("--max-diff-voxels", type=int, default=0)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    result = build_result(args.reference, args.candidate, args.affine_tolerance)

    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")

    if args.tsv_out:
        write_tsv(args.tsv_out, result)

    print_summary(result)

    if not result["shape_match"] or not result["affine_match"]:
        return 1

    if result["differing_voxels"] is None:
        return 1

    return 0 if result["differing_voxels"] <= args.max_diff_voxels else 1


if __name__ == "__main__":
    sys.exit(main())
