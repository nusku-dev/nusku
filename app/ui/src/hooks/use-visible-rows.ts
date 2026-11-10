import { useEffect, useRef, useState } from 'react'

export function useVisibleRows(count: number, rowHeight: number, overscan = 10) {
  const ref = useRef<HTMLDivElement>(null)
  const [view, setView] = useState({ top: 0, height: 0 })

  useEffect(() => {
    const element = ref.current
    if (!element) return
    const update = () => setView({ top: element.scrollTop, height: element.clientHeight })
    update()
    element.addEventListener('scroll', update, { passive: true })
    const observer = new ResizeObserver(update)
    observer.observe(element)
    return () => {
      element.removeEventListener('scroll', update)
      observer.disconnect()
    }
  }, [])

  const start = Math.max(0, Math.floor(view.top / rowHeight) - overscan)
  const end = Math.min(count, Math.ceil((view.top + view.height) / rowHeight) + overscan)
  const range = { start, end, before: start * rowHeight, after: Math.max(0, count - end) * rowHeight }
  return [ref, range] as const
}
