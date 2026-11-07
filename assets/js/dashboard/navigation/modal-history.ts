/** @format */
import { useCallback, useEffect } from 'react'
import { useLocation, useNavigate } from 'react-router-dom'
import { useAppNavigate } from './use-app-navigate'

/**
 * Modals (breakdowns, filter editor) are routes stacked on top of the dashboard.
 * Closing one used to push a new dashboard entry, which left the modal in the
 * history: pressing Back (or swiping back on mobile) reopened it, and leaving
 * the dashboard took several presses.
 *
 * We remember the history index of the last dashboard (root route) entry and
 * close modals by going back to it. When the modal was opened directly from a
 * URL there is no dashboard entry behind it, so we replace the modal entry.
 */
let dashboardRootIdx: number | null = null

const currentHistoryIdx = (): number | null => {
  const idx = window.history.state?.idx
  return typeof idx === 'number' ? idx : null
}

/** Mount once inside the router; records the index whenever the dashboard root is shown. */
export function useTrackDashboardRoot() {
  const location = useLocation()
  useEffect(() => {
    if (location.pathname === '/') {
      dashboardRootIdx = currentHistoryIdx()
    }
  }, [location])
}

export function useCloseModal() {
  const navigate = useNavigate()
  const appNavigate = useAppNavigate()
  return useCallback(() => {
    const idx = currentHistoryIdx()
    if (dashboardRootIdx !== null && idx !== null && dashboardRootIdx < idx) {
      navigate(dashboardRootIdx - idx)
    } else {
      appNavigate({ path: '/', search: (search) => search, replace: true })
    }
  }, [navigate, appNavigate])
}
