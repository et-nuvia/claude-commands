# Convert React Class Components to Functional

Migrate React class components to functional components with hooks.

---

## Context

Functional components with hooks are the modern React pattern. This prompt converts class components while preserving all functionality.

---

## Prerequisites

- React 16.8+ (hooks support)
- Understanding of hooks (useState, useEffect, useRef, etc.)
- Working test suite (recommended)

---

## Prompt

```
I want to convert this React project's class components to functional components with hooks.

## Analysis Phase

1. **Find all class components:**
   - Search for `class.*extends.*Component`
   - Search for `class.*extends.*PureComponent`
   - Check for `.jsx` and `.tsx` files

2. **For each component, identify:**
   - State usage (`this.state`, `this.setState`)
   - Lifecycle methods (componentDidMount, componentDidUpdate, etc.)
   - Refs (`this.refs`, `createRef`)
   - Context usage
   - Error boundaries
   - Instance methods and properties

3. **Identify complex patterns:**
   - Components using `getDerivedStateFromProps`
   - Components using `getSnapshotBeforeUpdate`
   - Error boundaries (must stay as classes)
   - Components with complex shouldComponentUpdate

## Conversion Mappings

### State

```tsx
// Before (Class)
class Counter extends Component {
  state = { count: 0 };

  increment = () => {
    this.setState({ count: this.state.count + 1 });
  };

  render() {
    return <button onClick={this.increment}>{this.state.count}</button>;
  }
}

// After (Functional)
function Counter() {
  const [count, setCount] = useState(0);

  const increment = () => {
    setCount(count + 1);
    // Or: setCount(prev => prev + 1);
  };

  return <button onClick={increment}>{count}</button>;
}
```

### componentDidMount → useEffect

```tsx
// Before
class UserProfile extends Component {
  componentDidMount() {
    this.fetchUser();
  }

  fetchUser() {
    api.getUser(this.props.userId).then(user => {
      this.setState({ user });
    });
  }
}

// After
function UserProfile({ userId }) {
  const [user, setUser] = useState(null);

  useEffect(() => {
    api.getUser(userId).then(setUser);
  }, []); // Empty deps = componentDidMount

  return user ? <div>{user.name}</div> : <div>Loading...</div>;
}
```

### componentDidUpdate → useEffect with deps

```tsx
// Before
class UserProfile extends Component {
  componentDidUpdate(prevProps) {
    if (prevProps.userId !== this.props.userId) {
      this.fetchUser();
    }
  }
}

// After
function UserProfile({ userId }) {
  const [user, setUser] = useState(null);

  useEffect(() => {
    api.getUser(userId).then(setUser);
  }, [userId]); // Re-run when userId changes
}
```

### componentWillUnmount → useEffect cleanup

```tsx
// Before
class Timer extends Component {
  componentDidMount() {
    this.interval = setInterval(this.tick, 1000);
  }

  componentWillUnmount() {
    clearInterval(this.interval);
  }
}

// After
function Timer() {
  useEffect(() => {
    const interval = setInterval(tick, 1000);
    return () => clearInterval(interval); // Cleanup function
  }, []);
}
```

### Refs

```tsx
// Before
class TextInput extends Component {
  inputRef = createRef();

  focusInput = () => {
    this.inputRef.current.focus();
  };

  render() {
    return <input ref={this.inputRef} />;
  }
}

// After
function TextInput() {
  const inputRef = useRef(null);

  const focusInput = () => {
    inputRef.current?.focus();
  };

  return <input ref={inputRef} />;
}
```

### Instance variables (non-rendered data)

```tsx
// Before
class Component extends React.Component {
  lastClickTime = 0;

  handleClick = () => {
    this.lastClickTime = Date.now();
  };
}

// After
function Component() {
  const lastClickTime = useRef(0);

  const handleClick = () => {
    lastClickTime.current = Date.now();
  };
}
```

### shouldComponentUpdate → React.memo

```tsx
// Before
class ExpensiveList extends PureComponent {
  // PureComponent does shallow comparison
}

// Or with shouldComponentUpdate
class ExpensiveList extends Component {
  shouldComponentUpdate(nextProps) {
    return nextProps.items !== this.props.items;
  }
}

// After
const ExpensiveList = React.memo(function ExpensiveList({ items }) {
  return <ul>{items.map(item => <li key={item.id}>{item.name}</li>)}</ul>;
});

// With custom comparison
const ExpensiveList = React.memo(
  function ExpensiveList({ items }) {
    return <ul>{items.map(item => <li key={item.id}>{item.name}</li>)}</ul>;
  },
  (prevProps, nextProps) => prevProps.items === nextProps.items
);
```

### Context

```tsx
// Before
class ThemedButton extends Component {
  static contextType = ThemeContext;

  render() {
    return <button style={{ color: this.context.color }}>Click</button>;
  }
}

// After
function ThemedButton() {
  const theme = useContext(ThemeContext);
  return <button style={{ color: theme.color }}>Click</button>;
}
```

### getDerivedStateFromProps → useMemo or useEffect

```tsx
// Before
class List extends Component {
  static getDerivedStateFromProps(props, state) {
    if (props.items !== state.prevItems) {
      return {
        prevItems: props.items,
        filteredItems: props.items.filter(item => item.active),
      };
    }
    return null;
  }
}

// After - use useMemo for derived data
function List({ items }) {
  const filteredItems = useMemo(
    () => items.filter(item => item.active),
    [items]
  );
}
```

### Callback optimization

```tsx
// Before
class Form extends Component {
  handleSubmit = (e) => {
    e.preventDefault();
    this.props.onSubmit(this.state.value);
  };
}

// After - useCallback for stable references
function Form({ onSubmit }) {
  const [value, setValue] = useState('');

  const handleSubmit = useCallback((e) => {
    e.preventDefault();
    onSubmit(value);
  }, [onSubmit, value]);

  return <form onSubmit={handleSubmit}>...</form>;
}
```

## Keep as Class Components

**Error Boundaries must stay as classes:**
```tsx
class ErrorBoundary extends Component {
  state = { hasError: false };

  static getDerivedStateFromError(error) {
    return { hasError: true };
  }

  componentDidCatch(error, errorInfo) {
    logError(error, errorInfo);
  }

  render() {
    if (this.state.hasError) {
      return <FallbackUI />;
    }
    return this.props.children;
  }
}
```

## Conversion Order

1. Start with leaf components (no children components)
2. Move up to container components
3. Keep error boundaries as classes
4. Convert one component at a time
5. Run tests after each conversion

## Validation

After each conversion:
- Component renders correctly
- State updates work
- Effects run at right times
- Cleanup happens on unmount
- All tests pass

Now analyze this project and convert class components to functional components.
```

---

## Rollback

If migration causes issues:
1. `git checkout -- path/to/Component.tsx`
2. Component-by-component revert as needed
