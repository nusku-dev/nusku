import { useEffect, useState } from 'react'

/**
 * The current time, updated every `everyMs`. Anything that renders relative time ("2 min ago")
 * must take `now` from here: the React Compiler memoizes on inputs, so a `Date.now()` hidden
 * inside a formatter would freeze at its first value.
 */
export function useNow(everyMs = 1000): number {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), everyMs)
    return () => clearInterval(timer)
  }, [everyMs])
  return now
}
