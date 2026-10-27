const colors = require('tailwindcss/colors')
const plugin = require('tailwindcss/plugin')

module.exports = {
  content: [
    "./js/**/*.{js,ts,tsx}",
    "../lib/*_web.ex",
    "../lib/*_web/**/*.*ex",
    "../extra/**/*.*ex",
  ],
  safelist: [
    // PlausibleWeb.StatsView.stats_container_class/1 uses this class
    // it's not used anywhere else in the templates or scripts
    "max-w-screen-xl"
  ],
  darkMode: 'class',
  theme: {
    container: {
      center: true,
      padding: '1rem',
    },
    extend: {
      colors: {
        yellow: colors.amber, // We started usign `yellow` in v2 but it was renamed to `amber` in v3 https://tailwindcss.com/docs/upgrade-guide#removed-color-aliases
        // Recount theme: cool neutral grays and the Petrol brand color, replacing slate and indigo
        gray: {
          50: '#f6f7f9',
          100: '#eef0f3',
          200: '#e2e5ea',
          300: '#cbd0d7',
          400: '#9aa2ae',
          500: '#6b7380',
          600: '#59616d',
          700: '#3f4651',
          800: '#262b33',
          900: '#15181d',
          950: '#0d0f12'
        },
        'gray-950': '#0d0f12',
        'gray-850': '#1a1e24',
        'gray-825': '#21262d',
        indigo: {
          50: '#ecf7fa',
          100: '#d3edf3',
          200: '#a9dbe7',
          300: '#75c3d6',
          400: '#3fa6bf',
          500: '#1993ae',
          600: '#0b6e86',
          700: '#0b5a6e',
          800: '#0d4a5a',
          900: '#0e3d4a',
          950: '#082730'
        }
      },
      spacing: {
        '44': '11rem'
      },
      width: {
        'content': 'fit-content'
      },
      opacity: {
        '15': '0.15',
      },
      zIndex: {
        '9': 9,
      },
      maxWidth: {
        '2xs': '15rem',
        '3xs': '12rem',
      },
      transitionProperty: {
        'padding': 'padding',
      }
    },
  },
  plugins: [
    require('@tailwindcss/forms'),
    require('@tailwindcss/aspect-ratio'),
    plugin(({ addVariant }) => addVariant("phx-no-feedback", [".phx-no-feedback&", ".phx-no-feedback &"])),
    plugin(({ addVariant }) => addVariant("phx-click-loading", [".phx-click-loading&", ".phx-click-loading &"])),
    plugin(({ addVariant }) => addVariant("phx-submit-loading", [".phx-submit-loading&", ".phx-submit-loading &"])),
    plugin(({ addVariant }) => addVariant("phx-change-loading", [".phx-change-loading&", ".phx-change-loading &"])),
  ]
}
