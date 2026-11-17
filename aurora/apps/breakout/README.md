# Aurora Live Breakout

A playable Breakout game in the Aurora v2 live module. The game runs in a
separate D process against `aurora-host`; the generic dev supervisor keeps the
host window open, rebuilds changed source, and swaps the new game in.

## Main workflow

From `aurora-host/`:

```text
aurora-hotswap.exe dev --source ../apps/breakout/module.d --host aurora-host.exe --out build/live-dev --watch 600 --events pointer --title "Live Breakout"
```

This is the iterative workflow:

1. The host window opens and stays open.
2. The supervisor builds `module.d` and starts build 1.
3. Leave the command running and edit `module.d`.
4. On every save it builds a new generation, reloads the host scene, and swaps
   the new game into the same host.
5. The host PID and game state stay alive; build IDs identify each generation.
6. `--hold` keeps the window open after the watch window if needed.

Nothing in the host supervisor knows about paddles, scores, or bricks. Those
live only in this project’s `module.d` and its test.

## Breakout project test

The project test performs the live edit for you:

```text
python -B ../apps/breakout/dev_swap_test.py
```

It copies `module.d`, starts the generic `dev` session, waits for the first
build, changes `PaddleWidth`, and verifies a second build and changed frames.
Paddle knowledge stays in the project test; the host tool only builds and
swaps.

## Game source

- `PaddleWidth` — paddle width in logical pixels.
- `BallSpeed` — initial ball speed.
- `Revision` — project state identity; a width edit does not need to change it.
- Brick colors, collision rules, input, and auto-play are ordinary D code.

State is carried through the module state file: build ID, score, lives, paddle
position, ball position/velocity, and the brick grid.

## Input

The scene opts into pointer events with `--events pointer`. The module reads the
shared input ring and moves the paddle. If there is no pointer input, the paddle
follows the ball so the game keeps playing.

## Boundary

Compile-and-swap is deliberate: the host stays the stable window and tree, and
edited D code becomes a new module process. There is no unsafe in-process code
patching.
