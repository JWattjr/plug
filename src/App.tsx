import { lazy, Suspense } from 'react'
import { BrowserRouter, Route, Routes } from 'react-router-dom'
import { Layout } from '@/components/Layout'
import { Skeleton } from '@/components/ui'
import Home from '@/pages/Home'

const Advertise = lazy(() => import('@/pages/Advertise'))
const Offers = lazy(() => import('@/pages/Offers'))
const Agent = lazy(() => import('@/pages/Agent'))
const Checkout = lazy(() => import('@/pages/Checkout'))
const Earnings = lazy(() => import('@/pages/Earnings'))

function NotFound() {
  return (
    <div className="card mx-auto max-w-md p-8 text-center">
      <h1 className="display text-2xl font-bold">Page not found</h1>
      <p className="mt-2 text-sm" style={{ color: 'var(--muted)' }}>That page does not exist.</p>
      <a className="btn btn-primary mt-5" href="/">Back home</a>
    </div>
  )
}

export default function App() {
  return (
    <BrowserRouter>
      <Suspense fallback={<div className="mx-auto max-w-6xl px-4 py-12"><Skeleton className="h-64 !rounded-3xl" /></div>}>
        <Routes>
          <Route element={<Layout />}>
            <Route index element={<Home />} />
            <Route path="advertise" element={<Advertise />} />
            <Route path="offers" element={<Offers />} />
            <Route path="agent" element={<Agent />} />
            <Route path="checkout/:id" element={<Checkout />} />
            <Route path="earnings/:address" element={<Earnings />} />
            <Route path="*" element={<NotFound />} />
          </Route>
        </Routes>
      </Suspense>
    </BrowserRouter>
  )
}
