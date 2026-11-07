import React, { useEffect, useState } from 'react'
import classNames from 'classnames'
import Modal from './modal'
import * as api from '../../api'
import * as url from '../../util/url'
import { useQueryContext } from '../../query-context'
import { useSiteContext } from '../../site-context'
import { durationFormatter } from '../../util/number-formatter'

// Keep in sync with Plausible.Ingestion.Traffic
export const REASON_LABELS = {
  bot_ua: 'Known bot user agent',
  headless_ua: 'Headless browser or HTTP client',
  webdriver: 'Browser reported automation (webdriver)',
  automation_globals: 'Automation framework detected',
  zero_window: 'Window has no size',
  no_languages: 'Browser has no languages',
  unknown_ua: 'Unrecognised browser',
  no_device: 'Unknown device type',
  datacenter_ip: 'Cloud provider IP address'
}

const reasonLabel = (reason) => REASON_LABELS[reason] || reason

function ClassBadge({ value }) {
  return (
    <span
      className={classNames(
        'inline-block px-2 py-0.5 rounded text-xs font-medium',
        value === 'bot'
          ? 'bg-red-100 text-red-700 dark:bg-red-900/40 dark:text-red-300'
          : 'bg-amber-100 text-amber-700 dark:bg-amber-900/40 dark:text-amber-300'
      )}
    >
      {value === 'bot' ? 'Bot' : 'Suspicious'}
    </span>
  )
}

function formatStart(start) {
  return start.replace('T', ' ').slice(0, 16)
}

function describeClient(visit) {
  const parts = [visit.browser, visit.operating_system, visit.device].filter(Boolean)
  return parts.length > 0 ? parts.join(' · ') : '(not set)'
}

export default function SuspiciousVisitorsModal() {
  const { query } = useQueryContext()
  const site = useSiteContext()
  const [state, setState] = useState({ loading: true, data: null, error: null })

  useEffect(() => {
    setState({ loading: true, data: null, error: null })
    api
      .get(url.apiPath(site, '/suspicious-visitors'), query)
      .then((data) => setState({ loading: false, data, error: null }))
      .catch((error) => setState({ loading: false, data: null, error }))
  }, [site, query])

  function renderReasons(reasons, total) {
    if (reasons.length === 0) return null

    return (
      <div className="mb-6">
        <h2 className="text-sm font-bold text-gray-700 dark:text-gray-300 mb-2">Why they were not counted</h2>
        <ul className="space-y-1">
          {reasons.map(({ reason, visits }) => (
            <li key={reason} className="flex justify-between text-sm text-gray-700 dark:text-gray-300">
              <span>{reasonLabel(reason)}</span>
              <span className="font-medium">
                {visits} <span className="text-gray-500">({Math.round((visits / total) * 100)}%)</span>
              </span>
            </li>
          ))}
        </ul>
      </div>
    )
  }

  function renderVisits(visits, total) {
    if (visits.length === 0) {
      return <p className="text-sm text-gray-500 dark:text-gray-400">No suspicious or bot visits in this period.</p>
    }

    return (
      <>
        <table className="w-full text-sm text-left text-gray-700 dark:text-gray-300 table-fixed">
          <thead>
            <tr className="text-xs font-bold text-gray-500 dark:text-gray-400 tracking-wide">
              <th className="p-2 w-32">Started</th>
              <th className="p-2 w-24">Class</th>
              <th className="p-2">Entry page</th>
              <th className="p-2 hidden md:table-cell">Client</th>
              <th className="p-2 w-36">Reasons</th>
            </tr>
          </thead>
          <tbody>
            {visits.map((visit, index) => (
              <tr key={index} className="border-t border-gray-100 dark:border-gray-700 align-top">
                <td className="p-2 whitespace-nowrap">{formatStart(visit.start)}</td>
                <td className="p-2"><ClassBadge value={visit.class} /></td>
                <td className="p-2 break-all">
                  {visit.entry_page}
                  <div className="text-xs text-gray-500 dark:text-gray-400">
                    {visit.pageviews} {visit.pageviews === 1 ? 'pageview' : 'pageviews'}
                    {visit.duration > 0 && ` · ${durationFormatter(visit.duration)}`}
                    {visit.interacted && ' · interacted'}
                    {visit.country && ` · ${visit.country}`}
                    {visit.source && ` · ${visit.source}`}
                  </div>
                </td>
                <td className="p-2 hidden md:table-cell">{describeClient(visit)}</td>
                <td className="p-2 text-xs">
                  {visit.reasons.map((reason) => (
                    <div key={reason}>{reasonLabel(reason)}</div>
                  ))}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        {total > visits.length && (
          <p className="mt-4 text-xs text-gray-500 dark:text-gray-400">Showing the latest {visits.length} of {total} visits.</p>
        )}
      </>
    )
  }

  function renderBody() {
    if (state.loading) {
      return <div className="mx-auto my-24 loading"><div></div></div>
    }
    if (state.error) {
      return <p className="text-sm text-red-600">Could not load suspicious visits.</p>
    }

    const { visits, reasons, total } = state.data
    return (
      <>
        {renderReasons(reasons, total)}
        {renderVisits(visits, total)}
      </>
    )
  }

  return (
    <Modal>
      <h1 className="text-xl font-bold dark:text-gray-100">Suspicious &amp; bot visits</h1>
      <p className="mt-1 mb-6 text-sm text-gray-500 dark:text-gray-400">
        Visits left out of your stats. Dashboard filters are not applied here.
      </p>
      {renderBody()}
    </Modal>
  )
}
