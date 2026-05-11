#!/usr/bin/env python3
"""Fast post-processing helpers for HCP-MMP1 parcellation volumes."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path


def import_dependencies():
    try:
        import nibabel as nib
        import numpy as np
    except ImportError as error:
        raise SystemExit(
            "This helper needs nibabel and numpy. Install them or set "
            "HCPMMP1_POSTPROCESS=fsl to use fslmaths."
        ) from error

    return nib, np


def load_label_volume(path: Path):
    nib, np = import_dependencies()
    image = nib.load(str(path))
    data = np.asanyarray(image.dataobj)

    if np.issubdtype(data.dtype, np.floating):
        rounded = np.rint(data)
        if not np.allclose(data, rounded, atol=1e-6, rtol=0):
            raise SystemExit(f"{path} contains non-integer label values.")
        data = rounded.astype(np.int32)
    else:
        data = data.astype(data.dtype, copy=True)

    return nib, np, image, data


def save_like(image, data, output_path: Path, dtype=None) -> None:
    nib, np = import_dependencies()
    output_path.parent.mkdir(parents=True, exist_ok=True)

    header = image.header.copy()
    if dtype is not None:
        data = data.astype(dtype)
        header.set_data_dtype(dtype)
    else:
        header.set_data_dtype(data.dtype)

    if hasattr(header, "set_slope_inter"):
        header.set_slope_inter(None, None)

    if "cal_min" in header and "cal_max" in header:
        header["cal_min"] = float(np.min(data)) if data.size else 0.0
        header["cal_max"] = float(np.max(data)) if data.size else 0.0

    nib.save(image.__class__(data, image.affine, header), str(output_path))


def command_check_dependencies(_: argparse.Namespace) -> int:
    import_dependencies()
    return 0


def command_hippocampus_fix(args: argparse.Namespace) -> int:
    _, _, image, data = load_label_volume(args.input)

    if args.left_index is not None:
        data[data == args.left_index] = 17

    if args.right_index is not None:
        data[data == args.right_index] = 53

    save_like(image, data, args.output)
    return 0


def read_mask_spec(path: Path) -> list[tuple[int, str]]:
    masks: list[tuple[int, str]] = []

    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue

            fields = line.split("\t")
            if len(fields) != 2:
                raise SystemExit(f"{path}:{line_number}: expected '<index>\\t<name>'.")

            try:
                index = int(fields[0])
            except ValueError as error:
                raise SystemExit(f"{path}:{line_number}: invalid index '{fields[0]}'.") from error

            name = fields[1]
            if os.path.basename(name) != name:
                raise SystemExit(f"{path}:{line_number}: mask name cannot contain a path.")

            masks.append((index, name))

    return masks


def command_write_masks(args: argparse.Namespace) -> int:
    _, np, image, data = load_label_volume(args.volume)
    masks = read_mask_spec(args.spec)
    args.output_dir.mkdir(parents=True, exist_ok=True)

    for index, name in masks:
        mask = (data == index).astype(np.uint8)
        save_like(image, mask, args.output_dir / f"{name}.nii.gz", dtype=np.uint8)

    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Post-process HCP-MMP1 parcellation volumes."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    check = subparsers.add_parser("check-dependencies")
    check.set_defaults(func=command_check_dependencies)

    hippocampus = subparsers.add_parser("hippocampus-fix")
    hippocampus.add_argument("--input", required=True, type=Path)
    hippocampus.add_argument("--output", required=True, type=Path)
    hippocampus.add_argument("--left-index", type=int)
    hippocampus.add_argument("--right-index", type=int)
    hippocampus.set_defaults(func=command_hippocampus_fix)

    masks = subparsers.add_parser("write-masks")
    masks.add_argument("--volume", required=True, type=Path)
    masks.add_argument("--spec", required=True, type=Path)
    masks.add_argument("--output-dir", required=True, type=Path)
    masks.set_defaults(func=command_write_masks)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
