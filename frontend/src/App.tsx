import { useEffect, useState } from "react";

interface User {
  email: string;
}

export function App() {
  const [user, setUser] = useState<User | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    fetch("/api/me")
      .then((r) => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        return r.json();
      })
      .then(setUser)
      .catch((e) => setError(String(e)));
  }, []);

  return (
    <main className="min-h-screen flex items-center justify-center p-6">
      <div className="max-w-lg w-full bg-white rounded-2xl shadow-sm border border-slate-200 p-8">
        <h1 className="text-2xl font-semibold mb-2">__APP_NAME__</h1>
        <p className="text-slate-500 mb-6">
          A quickship app — FastAPI on Lambda + Postgres + Cloudflare Access.
        </p>

        <div className="text-sm border-t border-slate-100 pt-4">
          <div className="text-slate-400 mb-1">Signed in as</div>
          {error ? (
            <div className="text-red-600">Error fetching /api/me: {error}</div>
          ) : user ? (
            <div className="font-mono text-slate-900">{user.email}</div>
          ) : (
            <div className="text-slate-400">…</div>
          )}
        </div>
      </div>
    </main>
  );
}
