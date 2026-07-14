# Pi Gateway

Production DNS gateway for Raspberry Pi 4B.

- [KURULUM.md](KURULUM.md) — kurulum
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — mimari
- [docs/OPERATIONS.md](docs/OPERATIONS.md) — günlük operasyon
- [docs/SECURITY.md](docs/SECURITY.md) — güvenlik

```bash
cp .env.example .env   # edit passwords + telegram
make install           # when Pi is online
make status            # remote health
make dns-test          # DNS checks from Mac
make backup-pull       # offsite restic copy
```
