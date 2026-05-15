# Next.js Development Guide

## Default Stack

| Component | Tool | Version/Notes |
|-----------|------|---------------|
| Framework | Next.js | 16.x (App Router) |
| Language | TypeScript | Strict mode |
| React | 19 | Server Components by default |
| Node.js | 24.x LTS | Latest LTS |
| Styling | Tailwind CSS | Utility-first |
| Testing (Unit) | Jest | With React Testing Library |
| Testing (E2E) | Playwright | Cross-browser |
| Linting | ESLint | With Next.js config |
| **Backend** | **Python/FastAPI** | See [Python Guide](python.md) |

**Default architecture**: Next.js frontend with Python/FastAPI backend unless project specifies otherwise.

Projects may override these in their project-specific CLAUDE.md.

---

## App Router Conventions

### File-Based Routing

```
src/app/
├── layout.tsx              # Root layout
├── page.tsx                # Home page (/)
├── loading.tsx             # Loading UI
├── error.tsx               # Error UI
├── not-found.tsx           # 404 page
├── users/
│   ├── page.tsx            # /users
│   ├── [id]/
│   │   ├── page.tsx        # /users/:id
│   │   └── edit/
│   │       └── page.tsx    # /users/:id/edit
│   └── new/
│       └── page.tsx        # /users/new
└── api/
    └── users/
        └── route.ts        # API route /api/users
```

### Special Files

| File | Purpose |
|------|---------|
| `layout.tsx` | Shared UI for a segment and its children |
| `page.tsx` | Unique UI for a route |
| `loading.tsx` | Loading UI (Suspense boundary) |
| `error.tsx` | Error UI (Error boundary) |
| `not-found.tsx` | 404 UI |
| `route.ts` | API endpoint |

### Server vs Client Components

**Server Components (default):**
```tsx
// No "use client" directive = Server Component
// Can: fetch data, access backend, use async/await
// Cannot: use hooks, browser APIs, event handlers

async function UserList() {
  const users = await fetchUsers();  // Direct data fetching
  return (
    <ul>
      {users.map(user => <li key={user.id}>{user.name}</li>)}
    </ul>
  );
}
```

**Client Components:**
```tsx
"use client";

// Required for: hooks, event handlers, browser APIs
import { useState } from "react";

function Counter() {
  const [count, setCount] = useState(0);
  return (
    <button onClick={() => setCount(c => c + 1)}>
      Count: {count}
    </button>
  );
}
```

**When to use which:**

| Use Server Components for | Use Client Components for |
|---------------------------|---------------------------|
| Data fetching | Interactivity (onClick, onChange) |
| Accessing backend resources | useState, useEffect, useRef |
| Keeping secrets on server | Browser APIs (localStorage, etc.) |
| Large dependencies | Real-time updates |

---

## TypeScript

### Strict Mode (Required)

```json
// tsconfig.json
{
  "compilerOptions": {
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "noImplicitReturns": true
  }
}
```

### Type Definitions

```tsx
// types/user.ts
export interface User {
  id: number;
  email: string;
  name: string;
  isActive: boolean;
  createdAt: Date;
}

export interface CreateUserRequest {
  email: string;
  name: string;
  password: string;
}

export interface UserListResponse {
  users: User[];
  total: number;
  page: number;
  pageSize: number;
}
```

### Component Props

```tsx
// Explicit interface for props
interface UserCardProps {
  user: User;
  onEdit?: (user: User) => void;
  className?: string;
}

function UserCard({ user, onEdit, className }: UserCardProps) {
  return (
    <div className={className}>
      <h3>{user.name}</h3>
      {onEdit && <button onClick={() => onEdit(user)}>Edit</button>}
    </div>
  );
}

// For children
interface LayoutProps {
  children: React.ReactNode;
  title: string;
}

function Layout({ children, title }: LayoutProps) {
  return (
    <div>
      <h1>{title}</h1>
      {children}
    </div>
  );
}
```

### API Responses

```tsx
// Type API responses
async function fetchUsers(): Promise<User[]> {
  const res = await fetch("/api/users");
  if (!res.ok) throw new Error("Failed to fetch users");
  return res.json();
}

// Use with loading states
interface FetchState<T> {
  data: T | null;
  isLoading: boolean;
  error: Error | null;
}
```

---

## Component Patterns

### Composition Over Complexity

```tsx
// Good - composable components
function Card({ children, className }: CardProps) {
  return <div className={cn("rounded-lg border p-4", className)}>{children}</div>;
}

function CardHeader({ children }: { children: React.ReactNode }) {
  return <div className="mb-4 font-semibold">{children}</div>;
}

function CardContent({ children }: { children: React.ReactNode }) {
  return <div>{children}</div>;
}

// Usage
<Card>
  <CardHeader>User Profile</CardHeader>
  <CardContent>
    <p>{user.name}</p>
  </CardContent>
</Card>

// Bad - monolithic component with many props
<UserCard
  title="User Profile"
  showHeader={true}
  headerClassName="font-bold"
  contentPadding="large"
  user={user}
  showActions={false}
/>
```

### Custom Hooks

Extract reusable logic into hooks:

```tsx
// hooks/useUsers.ts
"use client";

import { useState, useEffect } from "react";
import { User } from "@/types/user";

interface UseUsersResult {
  users: User[];
  isLoading: boolean;
  error: Error | null;
  refetch: () => void;
}

export function useUsers(): UseUsersResult {
  const [users, setUsers] = useState<User[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<Error | null>(null);

  const fetchUsers = async () => {
    setIsLoading(true);
    setError(null);
    try {
      const res = await fetch("/api/users");
      if (!res.ok) throw new Error("Failed to fetch");
      setUsers(await res.json());
    } catch (e) {
      setError(e instanceof Error ? e : new Error("Unknown error"));
    } finally {
      setIsLoading(false);
    }
  };

  useEffect(() => {
    fetchUsers();
  }, []);

  return { users, isLoading, error, refetch: fetchUsers };
}
```

### Error Boundaries

```tsx
// app/users/error.tsx
"use client";

interface ErrorProps {
  error: Error & { digest?: string };
  reset: () => void;
}

export default function Error({ error, reset }: ErrorProps) {
  return (
    <div className="flex flex-col items-center gap-4 p-8">
      <h2 className="text-xl font-semibold">Something went wrong</h2>
      <p className="text-gray-600">{error.message}</p>
      <button
        onClick={reset}
        className="rounded bg-blue-500 px-4 py-2 text-white"
      >
        Try again
      </button>
    </div>
  );
}
```

---

## Data Fetching

### Server Components (Preferred)

```tsx
// app/users/page.tsx
async function UsersPage() {
  const users = await fetch("http://api:8000/users", {
    cache: "no-store", // or "force-cache" for static
  }).then(res => res.json());

  return <UserList users={users} />;
}
```

### With Loading States

```tsx
// app/users/loading.tsx
export default function Loading() {
  return <UserListSkeleton />;
}

// app/users/page.tsx
import { Suspense } from "react";

async function UsersPage() {
  return (
    <Suspense fallback={<UserListSkeleton />}>
      <UserList />
    </Suspense>
  );
}
```

### API Routes

```tsx
// app/api/users/route.ts
import { NextRequest, NextResponse } from "next/server";

export async function GET(request: NextRequest) {
  const users = await fetchUsersFromDB();
  return NextResponse.json(users);
}

export async function POST(request: NextRequest) {
  const body = await request.json();

  // Validate
  if (!body.email || !body.name) {
    return NextResponse.json(
      { error: "Missing required fields" },
      { status: 400 }
    );
  }

  const user = await createUser(body);
  return NextResponse.json(user, { status: 201 });
}
```

---

## Project Structure

### Standard Layout

```
frontend/
├── src/
│   ├── app/                    # Next.js App Router
│   │   ├── layout.tsx          # Root layout
│   │   ├── page.tsx            # Home page
│   │   ├── globals.css         # Global styles
│   │   └── (routes)/           # Route groups
│   ├── components/             # React components
│   │   ├── ui/                 # Generic UI components
│   │   │   ├── Button.tsx
│   │   │   ├── Card.tsx
│   │   │   └── Input.tsx
│   │   └── features/           # Feature-specific components
│   │       ├── users/
│   │       │   ├── UserCard.tsx
│   │       │   └── UserList.tsx
│   │       └── auth/
│   │           └── LoginForm.tsx
│   ├── hooks/                  # Custom React hooks
│   │   ├── useUsers.ts
│   │   └── useAuth.ts
│   ├── services/               # API clients
│   │   ├── api.ts              # Base API client
│   │   └── users.ts            # User API functions
│   ├── types/                  # TypeScript types
│   │   ├── user.ts
│   │   └── api.ts
│   ├── utils/                  # Utility functions
│   │   ├── cn.ts               # className utility
│   │   └── format.ts           # Formatting helpers
│   └── lib/                    # Third-party integrations
│       └── auth.ts
├── public/                     # Static assets
├── tests/
│   ├── e2e/                    # Playwright E2E tests
│   └── unit/                   # Jest unit tests
├── tailwind.config.ts
├── next.config.ts
├── tsconfig.json
├── jest.config.js
├── playwright.config.ts
└── package.json
```

### Import Aliases

```json
// tsconfig.json
{
  "compilerOptions": {
    "baseUrl": ".",
    "paths": {
      "@/*": ["./src/*"],
      "@/components/*": ["./src/components/*"],
      "@/hooks/*": ["./src/hooks/*"],
      "@/types/*": ["./src/types/*"]
    }
  }
}
```

Usage:
```tsx
import { Button } from "@/components/ui/Button";
import { useUsers } from "@/hooks/useUsers";
import type { User } from "@/types/user";
```

---

## Styling with Tailwind

### Utility Classes

```tsx
// Good - utility classes
function Card({ children }: { children: React.ReactNode }) {
  return (
    <div className="rounded-lg border border-gray-200 bg-white p-4 shadow-sm">
      {children}
    </div>
  );
}

// Good - extract repeated patterns
const buttonStyles = {
  primary: "bg-blue-500 text-white hover:bg-blue-600",
  secondary: "bg-gray-100 text-gray-900 hover:bg-gray-200",
};

function Button({ variant = "primary", ...props }: ButtonProps) {
  return <button className={cn("rounded px-4 py-2", buttonStyles[variant])} {...props} />;
}
```

### Class Merging Utility

```tsx
// utils/cn.ts
import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

// Usage
<div className={cn("p-4", isActive && "bg-blue-500", className)} />
```

---

## Testing

### Unit Tests (Jest)

```tsx
// tests/unit/components/UserCard.test.tsx
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { UserCard } from "@/components/features/users/UserCard";

const mockUser = {
  id: 1,
  name: "John Doe",
  email: "john@example.com",
  isActive: true,
};

describe("UserCard", () => {
  it("renders user name", () => {
    render(<UserCard user={mockUser} />);
    expect(screen.getByText("John Doe")).toBeInTheDocument();
  });

  it("calls onEdit when edit button clicked", async () => {
    const onEdit = jest.fn();
    render(<UserCard user={mockUser} onEdit={onEdit} />);

    await userEvent.click(screen.getByRole("button", { name: /edit/i }));

    expect(onEdit).toHaveBeenCalledWith(mockUser);
  });

  it("hides edit button when onEdit not provided", () => {
    render(<UserCard user={mockUser} />);
    expect(screen.queryByRole("button", { name: /edit/i })).not.toBeInTheDocument();
  });
});
```

### E2E Tests (Playwright)

```tsx
// tests/e2e/users.spec.ts
import { test, expect } from "@playwright/test";

test.describe("Users", () => {
  test("displays user list", async ({ page }) => {
    await page.goto("/users");

    await expect(page.getByRole("heading", { name: "Users" })).toBeVisible();
    await expect(page.getByTestId("user-list")).toBeVisible();
  });

  test("can create new user", async ({ page }) => {
    await page.goto("/users/new");

    await page.getByLabel("Name").fill("New User");
    await page.getByLabel("Email").fill("new@example.com");
    await page.getByRole("button", { name: "Create" }).click();

    await expect(page).toHaveURL(/\/users\/\d+/);
    await expect(page.getByText("New User")).toBeVisible();
  });
});
```

### Test Commands

```bash
# Unit tests
docker compose run --rm frontend npm test

# Unit tests with coverage
docker compose run --rm frontend npm test -- --coverage

# E2E tests
docker compose run --rm frontend npm run test:e2e

# E2E tests with UI
docker compose run --rm frontend npm run test:e2e -- --ui
```

---

## Forms

### Controlled Components

```tsx
"use client";

import { useState } from "react";

interface FormData {
  name: string;
  email: string;
}

function UserForm({ onSubmit }: { onSubmit: (data: FormData) => void }) {
  const [formData, setFormData] = useState<FormData>({ name: "", email: "" });
  const [errors, setErrors] = useState<Partial<FormData>>({});

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();

    // Validate
    const newErrors: Partial<FormData> = {};
    if (!formData.name) newErrors.name = "Name is required";
    if (!formData.email) newErrors.email = "Email is required";

    if (Object.keys(newErrors).length > 0) {
      setErrors(newErrors);
      return;
    }

    onSubmit(formData);
  };

  return (
    <form onSubmit={handleSubmit}>
      <div>
        <label htmlFor="name">Name</label>
        <input
          id="name"
          value={formData.name}
          onChange={e => setFormData(d => ({ ...d, name: e.target.value }))}
        />
        {errors.name && <span className="text-red-500">{errors.name}</span>}
      </div>
      <button type="submit">Submit</button>
    </form>
  );
}
```

### Server Actions (Next.js 14+)

```tsx
// app/users/new/page.tsx
async function createUser(formData: FormData) {
  "use server";

  const name = formData.get("name") as string;
  const email = formData.get("email") as string;

  await fetch("http://api:8000/users", {
    method: "POST",
    body: JSON.stringify({ name, email }),
  });

  redirect("/users");
}

export default function NewUserPage() {
  return (
    <form action={createUser}>
      <input name="name" required />
      <input name="email" type="email" required />
      <button type="submit">Create User</button>
    </form>
  );
}
```

---

## Environment Variables

### Configuration

```bash
# .env.local (git-ignored)
NEXT_PUBLIC_API_URL=http://localhost:8000
API_SECRET_KEY=your-secret-key

# .env.example (committed)
NEXT_PUBLIC_API_URL=
API_SECRET_KEY=
```

### Usage

```tsx
// Client-side (must be prefixed with NEXT_PUBLIC_)
const apiUrl = process.env.NEXT_PUBLIC_API_URL;

// Server-side only
const secretKey = process.env.API_SECRET_KEY;

// Type-safe config
// lib/config.ts
export const config = {
  apiUrl: process.env.NEXT_PUBLIC_API_URL!,
  isProduction: process.env.NODE_ENV === "production",
} as const;
```

---

## Code Quality Commands

```bash
# Lint
docker compose run --rm frontend npm run lint

# Lint with fix
docker compose run --rm frontend npm run lint -- --fix

# Type check
docker compose run --rm frontend npm run typecheck

# Format (if using Prettier)
docker compose run --rm frontend npm run format

# All checks
docker compose run --rm frontend npm run lint && \
docker compose run --rm frontend npm run typecheck && \
docker compose run --rm frontend npm test
```

---

## ESLint Configuration

```js
// .eslintrc.js
module.exports = {
  extends: [
    "next/core-web-vitals",
    "plugin:@typescript-eslint/recommended",
  ],
  rules: {
    "@typescript-eslint/no-unused-vars": "error",
    "@typescript-eslint/no-explicit-any": "error",
    "prefer-const": "error",
    "no-console": "warn",
  },
};
```

---

## Code Examples

Implementation templates in [docs/code/](../code/):

- [Next.js + AWS Secrets Manager](../code/typescript/nextjs/secrets-aws.md)
- [Next.js + Infisical](../code/typescript/nextjs/secrets-infisical.md)

---

## Checklist

Before committing Next.js code:

- [ ] No TypeScript errors (`npm run typecheck`)
- [ ] No ESLint errors (`npm run lint`)
- [ ] All tests pass (`npm test`)
- [ ] E2E tests pass (`npm run test:e2e`)
- [ ] No `any` types (use proper typing)
- [ ] No console.log statements (use proper logging)
- [ ] Server Components where possible
- [ ] Client Components only when needed
- [ ] Proper error boundaries
- [ ] Loading states for async operations
