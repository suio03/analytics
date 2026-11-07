import React, { Fragment } from 'react'
import { Menu, Transition } from '@headlessui/react'
import { ChevronDownIcon } from '@heroicons/react/20/solid'
import classNames from 'classnames'
import { useQueryContext } from '../../query-context'
import { AppNavigationLink } from '../../navigation/use-app-navigate'

export const TRAFFIC_LABELS = {
  human: 'Humans',
  all: 'All traffic',
  suspicious: 'Suspicious',
  bot: 'Bots'
}

const OPTIONS = ['human', 'all', 'suspicious', 'bot']

export function TrafficPicker() {
  const { query } = useQueryContext()
  const current = query.traffic || 'human'

  return (
    <Menu as="div" className="relative inline-block pl-2" data-testid="traffic-picker">
      {({ open }) => (
        <>
          <Menu.Button
            className={classNames(
              'text-sm inline-flex focus:outline-none hover:text-indigo-600 dark:hover:text-indigo-600 items-center',
              current === 'human' ? 'text-gray-700 dark:text-gray-300' : 'text-amber-600 dark:text-amber-500 font-medium'
            )}
          >
            {TRAFFIC_LABELS[current]}
            <ChevronDownIcon className="ml-1 h-4 w-4" aria-hidden="true" />
          </Menu.Button>

          <Transition
            as={Fragment}
            show={open}
            enter="transition ease-out duration-100"
            enterFrom="opacity-0 scale-95"
            enterTo="opacity-100 scale-100"
            leave="transition ease-in duration-75"
            leaveFrom="opacity-100 scale-100"
            leaveTo="opacity-0 scale-95"
          >
            <Menu.Items
              static
              className="py-1 text-left origin-top-right absolute right-0 mt-2 w-44 rounded-md shadow-lg bg-white dark:bg-gray-800 ring-1 ring-black ring-opacity-5 focus:outline-none z-10"
            >
              {OPTIONS.map((option) => (
                <Menu.Item key={option} disabled={option === current}>
                  {({ active }) => (
                    <AppNavigationLink
                      search={(search) => ({ ...search, traffic: option === 'human' ? undefined : option })}
                      className={classNames(
                        {
                          'bg-gray-100 dark:bg-gray-900 text-gray-900 dark:text-gray-200': active,
                          'text-gray-700 dark:text-gray-200': !active,
                          'font-bold': option === current
                        },
                        'block px-4 py-2 text-sm'
                      )}
                    >
                      {TRAFFIC_LABELS[option]}
                    </AppNavigationLink>
                  )}
                </Menu.Item>
              ))}
            </Menu.Items>
          </Transition>
        </>
      )}
    </Menu>
  )
}
