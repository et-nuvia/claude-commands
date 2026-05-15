# React Framework Guide

## Overview

React SPA/frontend with Vite, TypeScript, and modern tooling.

---

## Default Stack

| Component | Tool | Version |
|-----------|------|---------|
| Runtime | Node.js | 24 LTS |
| Build Tool | Vite | Latest |
| UI Library | React | 19 |
| Styling | Tailwind CSS | Latest |
| Testing | Vitest + Playwright | Latest |
| State | TanStack Query | Latest |

---

## PROJECT.yaml Configuration

```yaml
languages:
  - name: typescript
    version: "5.0"
    root: "frontend"

testing:
  command: "npm test"
  coverage_command: "npm run test:cov"
  e2e_command: "npx playwright test"
  min_coverage: 80

quality:
  lint_command: "npm run lint"
  format_command: "npx prettier --write ."
  typecheck_command: "npx tsc --noEmit"

secrets:
  refresh:
    strategies:
      react:
        type: "file"
        template_dir: ".secrets-templates"
        target_files:
          - ".env"
          - ".env.production"
        rebuild_command: "npm run build"
```

---

## Project Structure

```
frontend/
├── src/
│   ├── main.tsx                # Entry point
│   ├── App.tsx                 # Root component
│   ├── components/
│   │   ├── ui/                 # Reusable UI components
│   │   └── features/           # Feature components
│   ├── pages/                  # Page components
│   ├── hooks/                  # Custom hooks
│   ├── lib/
│   │   ├── api.ts              # API client
│   │   └── utils.ts
│   ├── stores/                 # State management
│   └── types/                  # TypeScript types
├── public/
├── .secrets-templates/
│   └── .env.template
├── index.html
├── package.json
├── vite.config.ts
├── tailwind.config.ts
└── Dockerfile
```

---

## Environment Variables

React/Vite only exposes variables prefixed with `VITE_`:

```bash
# .env
VITE_API_URL=https://api.example.com
VITE_ANALYTICS_ID=UA-XXXXX
```

**Never put secrets in frontend env vars!** They're bundled and visible to users.

### Secret Template

```bash
# .secrets-templates/.env.template
VITE_API_URL=__SECRET_API_URL__
VITE_ANALYTICS_ID=__SECRET_ANALYTICS_ID__
```

---

## API Client

```typescript
// src/lib/api.ts
const API_URL = import.meta.env.VITE_API_URL;

class ApiClient {
  private baseUrl: string;
  private token: string | null = null;

  constructor(baseUrl: string) {
    this.baseUrl = baseUrl;
  }

  setToken(token: string | null) {
    this.token = token;
  }

  async get<T>(path: string): Promise<T> {
    const response = await fetch(`${this.baseUrl}${path}`, {
      headers: this.getHeaders(),
    });
    if (!response.ok) throw new Error(`API error: ${response.status}`);
    return response.json();
  }

  async post<T>(path: string, data: unknown): Promise<T> {
    const response = await fetch(`${this.baseUrl}${path}`, {
      method: 'POST',
      headers: this.getHeaders(),
      body: JSON.stringify(data),
    });
    if (!response.ok) throw new Error(`API error: ${response.status}`);
    return response.json();
  }

  private getHeaders(): HeadersInit {
    const headers: HeadersInit = {
      'Content-Type': 'application/json',
    };
    if (this.token) {
      headers['Authorization'] = `Bearer ${this.token}`;
    }
    return headers;
  }
}

export const api = new ApiClient(API_URL);
```

---

## TanStack Query Setup

```typescript
// src/main.tsx
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { ReactQueryDevtools } from '@tanstack/react-query-devtools';

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 1000 * 60 * 5, // 5 minutes
      retry: 1,
    },
  },
});

ReactDOM.createRoot(document.getElementById('root')!).render(
  <QueryClientProvider client={queryClient}>
    <App />
    <ReactQueryDevtools />
  </QueryClientProvider>
);
```

```typescript
// src/hooks/useUsers.ts
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { api } from '@/lib/api';

interface User {
  id: number;
  name: string;
  email: string;
}

export function useUsers() {
  return useQuery({
    queryKey: ['users'],
    queryFn: () => api.get<User[]>('/users'),
  });
}

export function useCreateUser() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (data: Omit<User, 'id'>) => api.post<User>('/users', data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['users'] });
    },
  });
}
```

---

## Component Example

```typescript
// src/pages/UsersPage.tsx
import { useUsers, useCreateUser } from '@/hooks/useUsers';

export function UsersPage() {
  const { data: users, isLoading, error } = useUsers();
  const createUser = useCreateUser();

  if (isLoading) return <div>Loading...</div>;
  if (error) return <div>Error: {error.message}</div>;

  return (
    <div>
      <h1>Users</h1>
      <ul>
        {users?.map(user => (
          <li key={user.id}>{user.name}</li>
        ))}
      </ul>
      <button
        onClick={() => createUser.mutate({ name: 'New User', email: 'new@example.com' })}
        disabled={createUser.isPending}
      >
        Add User
      </button>
    </div>
  );
}
```

---

## Dockerfile

```dockerfile
FROM node:24-alpine AS builder

WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .

ARG VITE_API_URL
ENV VITE_API_URL=$VITE_API_URL

RUN npm run build

FROM nginx:alpine

COPY --from=builder /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
```

**nginx.conf:**
```nginx
server {
    listen 80;
    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }

    location /api {
        proxy_pass http://backend:8000;
    }
}
```

---

## Commands

```bash
# Development
npm run dev

# Build
npm run build

# Preview production build
npm run preview

# Testing
npm test
npm run test:cov
npx playwright test

# Linting
npm run lint
npx prettier --check .
```

---

## Best Practices

1. **Don't put secrets in env vars** - They're visible in the bundle
2. **Use TanStack Query** - For server state management
3. **Lazy load routes** - Use React.lazy for code splitting
4. **Use TypeScript strictly** - No `any` types
5. **Test user interactions** - Not implementation details
