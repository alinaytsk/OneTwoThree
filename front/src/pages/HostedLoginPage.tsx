import { useEffect, useRef, useState } from "react"
import { LoaderCircle } from "lucide-react"
import { Link, Navigate } from "react-router"

import { AuthLayout } from "@/components/auth/AuthLayout"
import { authEnabled, startCognitoSignIn } from "@/lib/auth"

/**
 * `/login`: hands sign-in over to Cognito's own hosted page, which shows the email and password
 * form together with every provider the pool offers. This is the address to submit, rather than a
 * Cognito URL: the page builds the authorize request from the pool the app was built against, with
 * a fresh PKCE pair, so the link keeps working when the pool or its domain changes.
 */
export function HostedLoginPage() {
  const [error, setError] = useState<string | null>(null)
  // StrictMode runs effects twice in development; one redirect is enough.
  const started = useRef(false)

  useEffect(() => {
    if (!authEnabled() || started.current) return
    started.current = true
    startCognitoSignIn().catch((err: Error) => setError(err.message))
  }, [])

  // Without Cognito (local development) there are no hosted pages: use the app's own form.
  if (!authEnabled()) return <Navigate to="/" replace />

  return (
    <AuthLayout>
      {error ? (
        <div role="alert">
          <h1 className="text-2xl font-semibold text-foreground">Could not open sign-in</h1>
          <p className="mt-2 text-sm text-muted-foreground">{error}</p>
          <Link
            to="/"
            className="mt-6 inline-block font-medium text-primary underline-offset-4 hover:underline"
          >
            Back to sign in
          </Link>
        </div>
      ) : (
        <p className="flex items-center gap-2 text-muted-foreground">
          <LoaderCircle className="size-5 animate-spin" /> Taking you to sign in…
        </p>
      )}
    </AuthLayout>
  )
}
