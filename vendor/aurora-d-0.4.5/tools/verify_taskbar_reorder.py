#!/usr/bin/env python3
"""Deterministic model checks for Aurora's pointer-locked taskbar reorder contract.

This is a supplementary source/release check. The D integration test remains the
runtime authority because it exercises GuiWindow dispatch, capture, retained
layers, and late pointer latching.
"""
from __future__ import annotations

import math

MARGIN = 6.0
HYSTERESIS = 3.0


def clamp(value: int, low: int, high: int) -> int:
    return max(low, min(high, value))


def entry_width(taskbar_width: int, count: int) -> int:
    available = max(1, taskbar_width - 158)
    return clamp((available - max(0, count - 1) * 4) // count, 90, 180)


def target_index(
    current: int,
    pointer_x: float,
    taskbar_origin_x: float,
    grab_offset_x: float,
    count: int,
    width: int,
) -> int:
    stride = float(width) + 4.0
    proxy_center = pointer_x - taskbar_origin_x - grab_offset_x + width * 0.5
    first_center = 54.0 + width * 0.5
    target = clamp(current, 0, count - 1)
    while target + 1 < count:
        boundary = first_center + (target + 0.5) * stride
        if proxy_center <= boundary + HYSTERESIS:
            break
        target += 1
    while target > 0:
        boundary = first_center + (target - 0.5) * stride
        if proxy_center >= boundary - HYSTERESIS:
            break
        target -= 1
    return target


def move_once(order: list[int], source: int, target: int) -> list[int]:
    result = order.copy()
    value = result.pop(source)
    result.insert(target, value)
    return result


def main() -> int:
    checked_targets = 0
    checked_anchors = 0
    checked_commits = 0

    for count in range(2, 21):
        for taskbar_width in (480, 640, 800, 1100, 1920, 2560):
            width = entry_width(taskbar_width, count)
            stride = width + 4.0
            for source in range(count):
                original = list(range(count))
                for grab_offset in (0.0, width * 0.17, width * 0.5, width - 0.25):
                    for desired in range(count):
                        # Put the dragged proxy's centre exactly on the desired
                        # slot centre. The pointer itself remains at the grab point.
                        pointer_x = 137.25 + grab_offset + 54.0 + desired * stride
                        resolved = target_index(
                            source,
                            pointer_x,
                            137.25,
                            grab_offset,
                            count,
                            width,
                        )
                        if resolved != desired:
                            raise AssertionError(
                                f"target mismatch: n={count} width={taskbar_width} "
                                f"source={source} desired={desired} got={resolved}"
                            )
                        if original != list(range(count)):
                            raise AssertionError("preview mutated the model")
                        committed = move_once(original, source, desired)
                        expected = list(range(count))
                        value = expected.pop(source)
                        expected.insert(desired, value)
                        if committed != expected:
                            raise AssertionError("single-release commit mismatch")
                        checked_targets += 1
                        checked_commits += 1

                    # Circular and fractional motion must preserve the original
                    # grab point exactly; no slot quantization is allowed.
                    for sample in range(360):
                        angle = sample * math.tau / 360.0
                        pointer_x = 500.125 + math.cos(angle) * 219.75
                        pointer_y = 180.375 + math.sin(angle) * 91.5
                        proxy_x = pointer_x - grab_offset - MARGIN
                        proxy_y = pointer_y - 11.625 - MARGIN
                        anchor_x = proxy_x + MARGIN + grab_offset
                        anchor_y = proxy_y + MARGIN + 11.625
                        if not math.isclose(anchor_x, pointer_x, rel_tol=0.0, abs_tol=1e-12) \
                            or not math.isclose(anchor_y, pointer_y, rel_tol=0.0, abs_tol=1e-12):
                            raise AssertionError("drag proxy lost its pointer anchor")
                        checked_anchors += 1

    print(
        "Taskbar reorder model passed: "
        f"{checked_targets:,} target resolutions, "
        f"{checked_commits:,} one-shot commits, "
        f"{checked_anchors:,} pointer-anchor samples."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
