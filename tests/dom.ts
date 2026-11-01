import { GlobalRegistrator } from '@happy-dom/global-registrator'

// A DOM for rendering the real React screens. Network access is replaced by an in-memory fake chain.
GlobalRegistrator.register({ url: 'http://localhost:5173/advertise' })
;(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true

// framer-motion drives the Web Animations API, which happy-dom cancels with an unhandled rejection
// on unmount. Animations are cosmetic here, so render plain elements.
import { mock } from 'bun:test'
import { createElement, forwardRef, Fragment, type ReactNode } from 'react'

const MOTION_PROPS = new Set(['initial', 'animate', 'exit', 'transition', 'variants', 'whileHover', 'whileTap', 'whileInView', 'viewport', 'layout', 'layoutId'])

const plain = (tag: string) =>
  forwardRef<unknown, Record<string, unknown>>((props, ref) => {
    const rest = Object.fromEntries(Object.entries(props).filter(([k]) => !MOTION_PROPS.has(k)))
    return createElement(tag, { ...rest, ref })
  })

const cache = new Map<string, ReturnType<typeof plain>>()
const motion = new Proxy({}, { get: (_t, tag: string) => cache.get(tag) ?? (cache.set(tag, plain(tag)), cache.get(tag)) })

mock.module('framer-motion', () => ({
  motion,
  useReducedMotion: () => true,
  AnimatePresence: ({ children }: { children?: ReactNode }) => createElement(Fragment, null, children),
}))
