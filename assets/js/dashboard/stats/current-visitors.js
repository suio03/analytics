/** @format */

import React, { useCallback, useEffect, useState } from 'react'
import { AppNavigationLink } from '../navigation/use-app-navigate'
import * as api from '../api'
import { Tooltip } from '../util/tooltip'
import { SecondsSinceLastLoad } from '../util/seconds-since-last-load'
import { useQueryContext } from '../query-context'
import { useSiteContext } from '../site-context'
import { useLastLoadContext } from '../last-load-context'

export default function CurrentVisitors({ tooltipBoundary }) {
  const { query } = useQueryContext()
  const lastLoadTimestamp = useLastLoadContext()
  const site = useSiteContext()
  const [currentVisitors, setCurrentVisitors] = useState(null)

  const updateCount = useCallback(() => {
    api
      .get(`/api/stats/${encodeURIComponent(site.domain)}/current-visitors`, {}, {
        split: 'traffic'
      })
      .then((res) => setCurrentVisitors(res))
  }, [site.domain])

  useEffect(() => {
    document.addEventListener('tick', updateCount)

    return () => {
      document.removeEventListener('tick', updateCount)
    }
  }, [updateCount])

  useEffect(() => {
    updateCount()
  }, [query, updateCount])

  const humans = currentVisitors?.human ?? 0
  const nonHumans =
    (currentVisitors?.suspicious ?? 0) + (currentVisitors?.bot ?? 0)

  function tooltipInfo() {
    return (
      <div>
        {nonHumans > 0 && (
          <p className="whitespace-nowrap text-small">
            Not counted: {currentVisitors.suspicious} suspicious,{' '}
            {currentVisitors.bot} bot{currentVisitors.bot === 1 ? '' : 's'}
          </p>
        )}
        <p className="whitespace-nowrap text-small">
          Last updated{' '}
          <SecondsSinceLastLoad lastLoadTimestamp={lastLoadTimestamp} />s ago
        </p>
        <p className="whitespace-nowrap font-normal text-xs">
          Click to view realtime dashboard
        </p>
      </div>
    )
  }

  if (currentVisitors !== null && query.filters.length === 0) {
    return (
      <Tooltip info={tooltipInfo()} boundary={tooltipBoundary}>
        <AppNavigationLink
          search={(prev) => ({ ...prev, period: 'realtime' })}
          className="block ml-1 md:ml-2 mr-auto text-xs md:text-sm font-bold text-gray-500 dark:text-gray-300"
        >
          <svg
            className="inline w-2 mr-1 md:mr-2 text-green-500 fill-current"
            viewBox="0 0 16 16"
            xmlns="http://www.w3.org/2000/svg"
          >
            <circle cx="8" cy="8" r="8" />
          </svg>
          {humans}{' '}
          <span className="hidden sm:inline-block">
            current visitor{humans === 1 ? '' : 's'}
          </span>
          {nonHumans > 0 && (
            <span className="ml-1 font-normal text-gray-400 dark:text-gray-500">
              +{nonHumans} bot{nonHumans === 1 ? '' : 's'}
            </span>
          )}
        </AppNavigationLink>
      </Tooltip>
    )
  } else {
    return null
  }
}
