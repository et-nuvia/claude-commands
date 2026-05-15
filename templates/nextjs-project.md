# Next.js Project Rules

Copy this file to your project as `CLAUDE.md` or `.claude/CLAUDE.md`.

---

## Stack

- **Framework**: Next.js 16.x (App Router)
- **Language**: TypeScript (strict mode)
- **React**: 19.x
- **Node.js**: 24 LTS
- **Styling**: Tailwind CSS
- **Testing**: Jest (unit), Playwright (E2E)
- **Backend**: Python/FastAPI (separate service)

## Code Standards

- Strict TypeScript - no `any` types
- Server Components by default
- Client Components only when needed (`"use client"`)
- Proper error boundaries and loading states
- All API calls to Python backend, not API routes

## File Structure

```
app/
├── (auth)/              # Route groups
│   ├── login/
│   └── register/
├── dashboard/
│   ├── page.tsx         # Server Component
│   ├── loading.tsx      # Loading UI
│   └── error.tsx        # Error boundary
├── layout.tsx
└── globals.css
components/
├── ui/                  # Reusable UI components
├── forms/               # Form components
└── providers/           # Context providers (client)
lib/
├── api.ts               # API client to backend
└── utils.ts
types/
└── index.ts             # Shared type definitions
```

## Commands

```bash
# Run inside container only
docker compose run --rm frontend npm run lint       # Lint
docker compose run --rm frontend npm run format     # Format
docker compose run --rm frontend npm run typecheck  # Type check
docker compose run --rm frontend npm test           # Test
docker compose run --rm frontend npm run build      # Build
```

## Patterns

### Server Component (default)
```tsx
// app/users/page.tsx
import { getUsers } from '@/lib/api';

export default async function UsersPage() {
  const users = await getUsers();

  return (
    <div>
      <h1>Users</h1>
      <ul>
        {users.map((user) => (
          <li key={user.id}>{user.name}</li>
        ))}
      </ul>
    </div>
  );
}
```

### Client Component (when needed)
```tsx
// components/forms/LoginForm.tsx
"use client";

import { useState } from 'react';
import { useRouter } from 'next/navigation';

export function LoginForm() {
  const [email, setEmail] = useState('');
  const router = useRouter();

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    // Client-side logic here
    router.push('/dashboard');
  }

  return (
    <form onSubmit={handleSubmit}>
      <input
        type="email"
        value={email}
        onChange={(e) => setEmail(e.target.value)}
      />
      <button type="submit">Login</button>
    </form>
  );
}
```

### API Client
```typescript
// lib/api.ts
const API_URL = process.env.NEXT_PUBLIC_API_URL;

export async function getUsers(): Promise<User[]> {
  const res = await fetch(`${API_URL}/users`, {
    next: { revalidate: 60 }, // ISR: revalidate every 60s
  });

  if (!res.ok) {
    throw new Error('Failed to fetch users');
  }

  return res.json();
}
```

### Error Boundary
```tsx
// app/dashboard/error.tsx
"use client";

export default function Error({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  return (
    <div>
      <h2>Something went wrong!</h2>
      <button onClick={() => reset()}>Try again</button>
    </div>
  );
}
```

### Loading State
```tsx
// app/dashboard/loading.tsx
export default function Loading() {
  return <div>Loading...</div>;
}
```

### Test
```typescript
// __tests__/components/LoginForm.test.tsx
import { render, screen, fireEvent } from '@testing-library/react';
import { LoginForm } from '@/components/forms/LoginForm';

describe('LoginForm', () => {
  it('submits form with email', async () => {
    // Arrange
    render(<LoginForm />);

    // Act
    fireEvent.change(screen.getByRole('textbox'), {
      target: { value: 'test@example.com' },
    });
    fireEvent.click(screen.getByRole('button'));

    // Assert
    // ... assertions
  });
});
```
