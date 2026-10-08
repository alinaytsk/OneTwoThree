/**
 * Sign-in with Amazon Cognito, straight from the browser (no SDK): email + password through the
 * Cognito API, Google through the Hosted UI (OAuth code flow with PKCE). The ID token is sent to
 * our API, which verifies it.
 *
 * Without VITE_COGNITO_CLIENT_ID (local development without AWS) auth is disabled: any valid form
 * "signs in" and the backend treats every request as one local user.
 */

export interface AuthConfig {
  region: string
  clientId: string
  domain: string
  googleEnabled: boolean
}

export function authConfig(): AuthConfig {
  const env = import.meta.env
  return {
    region: env.VITE_COGNITO_REGION || "us-east-1",
    clientId: env.VITE_COGNITO_CLIENT_ID ?? "",
    domain: env.VITE_COGNITO_DOMAIN ?? "",
    googleEnabled: env.VITE_COGNITO_GOOGLE === "true" && Boolean(env.VITE_COGNITO_DOMAIN),
  }
}

export const authEnabled = () => Boolean(authConfig().clientId)
export const googleEnabled = () => authEnabled() && authConfig().googleEnabled

/** Cognito error with its exception name, e.g. NotAuthorizedException. */
export class AuthError extends Error {
  readonly code: string

  constructor(code: string, message: string) {
    super(message)
    this.name = "AuthError"
    this.code = code
  }
}

const FRIENDLY_MESSAGES: Record<string, string> = {
  NotAuthorizedException: "Incorrect email or password",
  UserNotFoundException: "Incorrect email or password",
  UsernameExistsException: "An account with this email already exists",
  CodeMismatchException: "That code is not right, check the email and try again",
  ExpiredCodeException: "The code has expired, send a new one",
  LimitExceededException: "Too many attempts, try again in a few minutes",
  TooManyRequestsException: "Too many attempts, try again in a few minutes",
}

async function cognito<T>(action: string, body: Record<string, unknown>): Promise<T> {
  const { region, clientId } = authConfig()
  const response = await fetch(`https://cognito-idp.${region}.amazonaws.com/`, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-amz-json-1.1",
      "X-Amz-Target": `AWSCognitoIdentityProviderService.${action}`,
    },
    body: JSON.stringify({ ClientId: clientId, ...body }),
  })
  const data = await response.json().catch(() => ({}))
  if (!response.ok) {
    const code =
      String(data.__type ?? "")
        .split("#")
        .pop() || "UnknownError"
    throw new AuthError(code, FRIENDLY_MESSAGES[code] ?? data.message ?? "Sign-in failed")
  }
  return data as T
}

// --- Session (kept in localStorage so a reload stays signed in) ---

interface Session {
  idToken: string
  refreshToken?: string
  /** Epoch ms when the ID token expires. */
  expiresAt: number
}

const SESSION_KEY = "meetings.session"
const LOCAL_SESSION: Session = { idToken: "", expiresAt: Number.MAX_SAFE_INTEGER }

function readSession(): Session | null {
  try {
    const raw = localStorage.getItem(SESSION_KEY)
    return raw ? (JSON.parse(raw) as Session) : null
  } catch {
    return null
  }
}

function writeSession(session: Session | null) {
  try {
    if (session) localStorage.setItem(SESSION_KEY, JSON.stringify(session))
    else localStorage.removeItem(SESSION_KEY)
  } catch {
    // Storage unavailable (private mode): the session lasts until reload.
  }
}

interface Tokens {
  IdToken: string
  RefreshToken?: string
  ExpiresIn: number
}

function saveTokens(tokens: Tokens, previousRefresh?: string) {
  writeSession({
    idToken: tokens.IdToken,
    refreshToken: tokens.RefreshToken ?? previousRefresh,
    expiresAt: Date.now() + tokens.ExpiresIn * 1000,
  })
}

/**
 * A stored session counts only when it can actually authenticate. With Cognito on, a session
 * without an ID token is a leftover from a build where auth was disabled: treating it as signed
 * in sends the user from /signup to /home and straight back here on the first 401, so the
 * sign-up form can never be reached.
 */
export function isSignedIn(): boolean {
  const session = readSession()
  if (!session) return false
  if (authEnabled() && !session.idToken) {
    writeSession(null)
    return false
  }
  return true
}

export function signOut() {
  writeSession(null)
}

/** A valid ID token for the API, refreshed when about to expire; null when signed out. */
export async function getIdToken(): Promise<string | null> {
  const session = readSession()
  if (!session || !authEnabled()) return null
  if (session.expiresAt - 60_000 > Date.now()) return session.idToken
  if (!session.refreshToken) {
    signOut()
    return null
  }
  try {
    const { AuthenticationResult } = await cognito<{ AuthenticationResult: Tokens }>(
      "InitiateAuth",
      { AuthFlow: "REFRESH_TOKEN_AUTH", AuthParameters: { REFRESH_TOKEN: session.refreshToken } },
    )
    saveTokens(AuthenticationResult, session.refreshToken)
    return AuthenticationResult.IdToken
  } catch {
    signOut()
    return null
  }
}

// --- Email + password ---

export async function signIn(email: string, password: string): Promise<void> {
  if (!authEnabled()) {
    writeSession(LOCAL_SESSION)
    return
  }
  const result = await cognito<{ AuthenticationResult?: Tokens; ChallengeName?: string }>(
    "InitiateAuth",
    { AuthFlow: "USER_PASSWORD_AUTH", AuthParameters: { USERNAME: email, PASSWORD: password } },
  )
  if (!result.AuthenticationResult) {
    throw new AuthError(
      result.ChallengeName ?? "ChallengeRequired",
      "This account needs an extra step that the app does not support yet",
    )
  }
  saveTokens(result.AuthenticationResult)
}

/** Creates the account; Cognito then emails a code to confirm it. */
export async function signUp(name: string, email: string, password: string): Promise<void> {
  if (!authEnabled()) return
  await cognito("SignUp", {
    Username: email,
    Password: password,
    UserAttributes: [
      { Name: "email", Value: email },
      { Name: "name", Value: name },
    ],
  })
}

export async function confirmSignUp(email: string, code: string): Promise<void> {
  if (!authEnabled()) return
  await cognito("ConfirmSignUp", { Username: email, ConfirmationCode: code })
}

export async function resendCode(email: string): Promise<void> {
  if (!authEnabled()) return
  await cognito("ResendConfirmationCode", { Username: email })
}

// --- Google (Hosted UI, authorization code + PKCE) ---

const PKCE_KEY = "meetings.pkce"
export const callbackUrl = () => `${window.location.origin}/auth/callback`

function base64Url(bytes: ArrayBuffer | Uint8Array): string {
  const binary = String.fromCharCode(...new Uint8Array(bytes))
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

export async function startGoogleSignIn(): Promise<void> {
  const { clientId, domain } = authConfig()
  const verifier = base64Url(crypto.getRandomValues(new Uint8Array(32)))
  const state = base64Url(crypto.getRandomValues(new Uint8Array(16)))
  const challenge = base64Url(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)),
  )
  sessionStorage.setItem(PKCE_KEY, JSON.stringify({ verifier, state }))
  const params = new URLSearchParams({
    identity_provider: "Google",
    response_type: "code",
    client_id: clientId,
    redirect_uri: callbackUrl(),
    scope: "openid email profile",
    state,
    code_challenge_method: "S256",
    code_challenge: challenge,
  })
  window.location.assign(`https://${domain}/oauth2/authorize?${params}`)
}

/** Exchanges the code from the Hosted UI redirect for tokens. */
export async function completeOAuthSignIn(code: string, state: string): Promise<void> {
  const { clientId, domain } = authConfig()
  const saved = JSON.parse(sessionStorage.getItem(PKCE_KEY) ?? "null") as {
    verifier: string
    state: string
  } | null
  sessionStorage.removeItem(PKCE_KEY)
  if (!saved || saved.state !== state) {
    throw new AuthError("StateMismatch", "Sign-in expired or was started elsewhere, try again")
  }
  const response = await fetch(`https://${domain}/oauth2/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      client_id: clientId,
      code,
      redirect_uri: callbackUrl(),
      code_verifier: saved.verifier,
    }),
  })
  const data = await response.json().catch(() => ({}))
  if (!response.ok)
    throw new AuthError(data.error ?? "TokenError", "Google sign-in failed, try again")
  saveTokens({
    IdToken: data.id_token,
    RefreshToken: data.refresh_token,
    ExpiresIn: data.expires_in,
  })
}
