# Contributing

Thanks for your interest in the orchestrator. Small, focused pull requests are easiest to review.

1. Open an issue first for anything larger than a bug fix, so we can agree on the approach.
2. Fork the repository and create a branch from `main`.
3. Keep changes minimal and match the existing style (see `.editorconfig`).
4. Run the checks before you push:

   ```sh
   for f in orchestrate.sh lane.sh router.sh; do zsh -n "$f"; done
   sh -n examples/openai-compatible-runner.sh
   ./scripts/setup.sh   # offline end-to-end test with the mock runner
   ```

5. Use conventional commit messages (`feat:`, `fix:`, `docs:`, `test:`, `chore:`).
6. Never commit secrets, real customer data or personal data. Use fictional examples.

By contributing you agree that your contribution is licensed under the MIT license of this project.
