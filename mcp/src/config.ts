// Config lives entirely in the environment (docs/DESIGN.md section 12: "PAT
// ไม่เคยเห็น basic auth credential" -- the token here is a PAT, not a Kong
// credential, but the same principle applies: nothing secret in source or
// argv, and a missing token fails at startup with a clear message rather
// than as a cryptic first-call 401.

export interface Config {
  apiUrl: string;
  token: string;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const token = env.KONGCTL_TOKEN?.trim();
  if (!token) {
    throw new Error(
      "KONGCTL_TOKEN is required -- issue a personal access token from the Kongsole web UI " +
        "(/personal_access_tokens) and set it in this server's environment."
    );
  }

  const apiUrl = (env.KONGCTL_API_URL ?? "http://localhost:3000/api/v1").replace(/\/+$/, "");

  return { apiUrl, token };
}
