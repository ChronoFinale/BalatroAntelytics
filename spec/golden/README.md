# Golden-File Scenario Tests

End-to-end tests that drive the **real production hooks** (`lib/hooks.lua`,
`lib/recorder.lua`, `lib/capture.lua`, `lib/serializer.lua`) against a
faked `G` global and compare the resulting JSON against checked-in
expected files. Mocks live only at the boundary (the `G` table).

## Why this exists

Pure unit tests prove individual modules work in isolation. The fixture
tests in `viewer/lib/__fixtures__/` prove the viewer parses real run
files. This layer fills the gap between them: it pins down the *exact
JSON shape* the mod writes for given gameplay sequences, so anything
that silently changes the schema fails loudly.

## Layout

```
spec/golden/
  README.md                       you are here
  runner_spec.lua                 busted spec — discovers and runs scenarios
  lib/
    world.lua                     fake-G test harness
    runner.lua                    discover/run/diff/regenerate logic
  scenarios/
    play_then_discard.lua         each scenario is a function(world)
    play_with_perma_bonus.lua
    discard_play_alternation.lua
  expected/
    play_then_discard.json        each scenario has a checked-in expected
    play_with_perma_bonus.json
    discard_play_alternation.json
```

## Running

```bash
# Compare against expected files (default; fails on diff)
busted spec/golden/runner_spec.lua

# Regenerate expected files after an intentional capture-format change
REGEN=1 busted spec/golden/runner_spec.lua
```

When a scenario fails, the test prints a unified diff with the first
differing line plus context. Inspect the diff: if the change was
intentional, run with `REGEN=1` and commit the updated `expected/*.json`
alongside the code change. If it wasn't, the test caught a regression.

## Writing a new scenario

A scenario is a Lua module that returns `function(world)`:

```lua
return function(world)
    -- Build a hand:
    world:set_hand({ ...card tables... })

    -- Highlight cards by index:
    world:highlight({ 1, 2, 3 })

    -- Tell the harness what hand-type the engine will report:
    world:next_play_hand_type("Three of a Kind")

    -- Drive an action through the production wrapper:
    world:play_hand()

    -- Repeat for as many actions as the scenario covers...
end
```

Then run `REGEN=1 busted spec/golden/runner_spec.lua` to create the
expected file, eyeball the JSON to confirm it's correct, and commit
both the scenario and the expected file together.

## Why the harness builds a fake G

Balatro is a Love2D app. Loading the real `G` requires the entire LÖVE
runtime: graphics, audio, sprite atlases, sound files, fonts. Worse,
core Balatro flows like `play_cards_from_highlighted` queue dozens of
animation events on `G.E_MANAGER` that need many frame ticks to resolve.

What we *do* run end-to-end is everything we wrote: the wrappers, the
recorder, the capture module, the serializer. The only fakery is the
shape of the data they read from the engine. That gives us the highest
leverage per line of test code.
