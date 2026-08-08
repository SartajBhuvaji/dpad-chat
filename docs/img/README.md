# Screenshots

Images used by [SCREENSHOTS.md](../../SCREENSHOTS.md) and [README.md](../../README.md).

| File | Shows |
| --- | --- |
| `apps.png` | Onion's Apps menu with D-Pad Chat selected |
| `app.png` | the tile on its own |
| `app_launch.png` | the app at launch, an empty prompt |
| `keyboard.png` | the on-screen keyboard raised |
| `question_ask.png` | a question typed, keyboard up |
| `question_thinking.png` | the waiting indicator, counting seconds |
| `question_answered.png` | a streamed reply, keyboard hidden |
| `chat_resumed.png` | a conversation resumed after reopening |
| `help.png` | `/help` |
| `about.png` | `/about` |
| `config.png` | `/config` |
| `update_1.png` | `/update` offering a newer version |
| `update_2.png` | `/update` staged, waiting for the next launch |

Not yet in use:

| File | Why |
| --- | --- |
| `chat_prev_game_prefilled*.png` | taken against v0.13.0, which left `{game}` unsubstituted in the prompt. Fixed since; retake and uncomment the section in SCREENSHOTS.md |
| `hero.jpg` | not taken yet — the device in hand, running a finished conversation |

Framebuffer captures where the point is the text, photographs where the point is the
device. Keep them under ~400 KB each — the repository ships to an SD card.

Captures are read straight off `/dev/fb0` over SSH and converted on a computer; the panel
is 640×480 BGRA and mounted upside down, so a raw read needs rotating 180°.
