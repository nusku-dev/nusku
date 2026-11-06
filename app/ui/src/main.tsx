import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { ThemeProvider } from 'next-themes'
import { Toaster } from '@/components/ui/sonner'
import { TooltipProvider } from '@/components/ui/tooltip'
import { DataSourceContext } from '@/data/hooks'
import { MockSource } from '@/data/mock/source'
import './style.css'
import App from './App.tsx'

// The one place that picks where data comes from. Sample data for now; the real backend is a
// second DataSource (see data/source.ts) chosen here.
const source = new MockSource()

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <ThemeProvider attribute="class" defaultTheme="dark" enableSystem disableTransitionOnChange>
      <DataSourceContext value={source}>
        <TooltipProvider>
          <App />
          <Toaster position="bottom-right" />
        </TooltipProvider>
      </DataSourceContext>
    </ThemeProvider>
  </StrictMode>,
)
