const { mockRequest } = require('./support/test-utils')
const { expect, test } = require('@playwright/test');

test.describe('Cookie mode', () => {
  test('sends the same visitor id across page loads and keeps it in a cookie', async ({ page, context }) => {
    let request = mockRequest(page, '/api/event')
    await page.goto('/simple.html');
    const first = (await request).postDataJSON().v
    expect(first).toMatch(/^[A-Za-z0-9]{20}$/)

    await page.unroute('/api/event')
    request = mockRequest(page, '/api/event')
    await page.reload()
    expect((await request).postDataJSON().v).toEqual(first)

    const cookies = await context.cookies()
    expect(cookies.find(c => c.name === 'rc_vid').value).toEqual(first)
    expect(await page.evaluate(() => window.plausible.visitorId)).toEqual(first)
  });

  test('data-cookieless sends no visitor id and stores nothing', async ({ page, context }) => {
    const request = mockRequest(page, '/api/event')
    await page.goto('/cookieless.html');
    expect((await request).postDataJSON().v).toBeUndefined()
    expect((await context.cookies()).find(c => c.name === 'rc_vid')).toBeUndefined()
  });
});
