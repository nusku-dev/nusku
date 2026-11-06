import { cn } from 'cn'
import type { Session, StopReason } from '@/lib/profile/types'

const reasons: Record<StopReason, string> = {
  duration: 'Duration reached',
  target_exited: 'Process exited',
  cancelled: 'Stopped',
}

function stopReasonText(reason: StopReason | null): string {
  return reason ? reasons[reason] : 'Finished'
}

/** A pulsing dot while the run goes. */
export function LiveDot({ className }: { className?: string }) {
  return (
    <span className={cn('relative flex size-2', className)}>
      <span className="absolute inline-flex size-full animate-ping rounded-full bg-emerald-500 opacity-60" />
      <span className="relative inline-flex size-2 rounded-full bg-emerald-500" />
    </span>
  )
}

export function SessionStatus({ session }: { session: Pick<Session, 'status' | 'reason'> }) {
  if (session.status === 'running') {
    return (
      <span className="inline-flex items-center gap-1.5 text-xs font-medium text-emerald-600 dark:text-emerald-400">
        <LiveDot /> Live
      </span>
    )
  }
  return (
    <span className="inline-flex items-center gap-1.5 text-xs text-muted-foreground">
      <span className={cn('size-2 rounded-full', session.reason === 'target_exited' ? 'bg-amber-500' : 'bg-muted-foreground/50')} />
      {stopReasonText(session.reason)}
    </span>
  )
}
