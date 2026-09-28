# Two-Player Reaction Game

PIC16F877A assembly firmware and a Proteus schematic for a two-player target-time reaction game.

## Canonical project files

- Firmware source: [ReactionGame-Assembly/main.asm](ReactionGame-Assembly/main.asm)
- MPLAB project: [ReactionGame-Assembly/ReactionGame_Assembly.mcp](ReactionGame-Assembly/ReactionGame_Assembly.mcp)
- Proteus schematic project: [ReactionGame-Schematic/ReactionGame.pdsprj](ReactionGame-Schematic/ReactionGame.pdsprj)

These are the maintained project files. Build outputs and temporary IDE files are not source files.

## How to play

1. Press the judge button once to display a randomly selected target from 0 to 60 seconds.
2. Press it again to start the round. Both player LEDs light during the ready period; they turn off at GO.
3. Each player presses their own button to stop their timer. A button held through GO must be released before it can register.
4. The player whose elapsed time is closest to the target earns a point. A tie earns neither player a point.
5. The first player to reach five points wins. Press the judge button to start a new game.

## Hardware and pin assignments

The firmware targets a PIC16F877A. Wire the circuit to match the Proteus schematic and these firmware assignments:

| PIC pins | Function                                         |
| -------- | ------------------------------------------------ |
| RB0      | Judge/master button, active low                  |
| RB1      | Player 1 button, active low                      |
| RB2      | Player 2 button, active low                      |
| RA0      | Player 1 LED                                     |
| RA1      | Player 2 LED                                     |
| RC0-RC7  | Seven-segment display segments and decimal point |
| RE0-RE2  | Digit-decoder address inputs A-C                 |
| RD0      | LCD RS                                           |
| RD1      | LCD enable                                       |
| RD2-RD5  | LCD data D4-D7 (4-bit mode)                      |

The firmware disables the PIC's PORTB weak pull-ups, so provide external pull-ups for RB0-RB2 and wire each button to pull its input low when pressed. Use current-limiting resistors and display/decoder polarity appropriate to the actual components in the schematic.

The source configures an XT oscillator and its Timer2 timing calculations assume a 4 MHz oscillator. Confirm the crystal/clock frequency in the circuit and use 4 MHz for simulation; changing it affects the timing and delay routines.

## Build and simulate

1. Install MPLAB/MPASM tooling that supports the PIC16F877A and legacy `.mcp` project files. The exact tool version used to create this project has not been recorded; record it when producing a verified release.
2. Open `ReactionGame-Assembly/ReactionGame_Assembly.mcp` and build the project. The assembler must be able to locate its `P16F877A.INC` device include.
3. Load the generated HEX into the PIC16F877A component in Proteus and open `ReactionGame-Schematic/ReactionGame.pdsprj`.
4. Set the simulated oscillator to 4 MHz and verify the circuit and gameplay before using the firmware on hardware.

Useful simulation checks include target display, ready-to-GO transition, each player's independent stop button, early/held button behavior, timeout, closer-time scoring, ties, five-point win, and game restart.

No automated build or simulation test is configured in this repository. A public release should identify the tested tool versions and record the results of the build and simulation checks above.

## Generated files

MPLAB/MPASM outputs such as HEX, listing, map, and debug files are ignored. If distributing a HEX, build it from the maintained assembly source and publish it as a versioned release artifact with the toolchain version recorded.

## License

No license has been selected. Public visibility alone does not grant permission to reuse, modify, or distribute this project's contents. Add a license before inviting reuse or contributions.
