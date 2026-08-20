# ex-cicd-tektonpac

Example Spring Boot (Java/Maven) application demonstrating a Tekton
**Pipelines as Code (PAC)** CI/CD setup, following the guide at
`~/doc.for_ai/tekton/tekton-pac-java-cicd-guide.md`.

- `.tekton/pr.yaml` — runs on pull requests against `main`: build + test,
  throwaway image build (no push).
- `.tekton/push.yaml` — runs on push to `main`: build + test, push the
  image to `ghcr.io/catsrang/demo-app`, then bump `image.tag` in the
  companion GitOps repo, [`ex-cicd-tektonpac-deploy`](https://github.com/catsrang/ex-cicd-tektonpac-deploy).
- `infra/pac/` — cluster-side setup docs/scripts (PAC install, GitHub App,
  Repository CR) for the target k3s cluster.

See `topic/20260820-1_init_tekton_cicd_example/` for the full spec, plan,
and phase-by-phase implementation log.

(Phase 8 retest commit, after adding app-repo to the App's installation.)
(retest after creating Repository CR for deploy-repo)
