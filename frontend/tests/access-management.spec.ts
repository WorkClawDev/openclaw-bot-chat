import { expect, test, type Page } from '@playwright/test'
import { fixture } from './fixtures/agent-chat'

async function adminFixture(page: Page) {
  const context = await fixture(page, 0)
  const accounts = [
    { id: 'ui-user', username: 'Alex', email: 'alex@example.invalid', role: 'admin', status: 1 },
    { id: 'ui-member', username: 'Jordan', email: 'jordan@example.invalid', role: 'user', status: 1 },
  ]
  const changes: unknown[] = []
  await page.route('**/api/v1/auth/me', route => route.fulfill({ json: { code: 0, data: accounts[0] } }))
  await page.route('**/api/v1/admin/users**', async route => {
    if (route.request().method() === 'PUT') {
      const update = route.request().postDataJSON()
      changes.push(update); Object.assign(accounts[1], update)
      await route.fulfill({ json: { code: 0, data: accounts[1] } })
    } else {
      const query = new URL(route.request().url()).searchParams.get('search') || ''
      const data = accounts.filter(row => row.username.toLowerCase().includes(query.toLowerCase()))
      await route.fulfill({ json: { code: 0, data, total: data.length, page: 1, per_page: 20, has_more: false } })
    }
  })
  return { ...context, changes }
}

test('administrator can suspend an account, search, and cannot edit their own access', async ({ page }) => {
  const context = await adminFixture(page)
  await page.goto('/admin/users')
  await expect(page.getByRole('heading', { name: 'Account access' })).toBeVisible()
  await expect(page.getByLabel('Role for Alex')).toBeDisabled()
  await expect(page.getByLabel('Status for Alex')).toBeDisabled()
  await page.getByLabel('Status for Jordan').selectOption('2')
  await page.getByRole('button', { name: 'Save access for Jordan' }).click()
  await expect(page.getByRole('status')).toHaveText('Access updated')
  expect(context.changes).toEqual([{ role: 'user', status: 2 }])
  await page.screenshot({ path: '../run/mqtts-permissions/access-desktop.png', fullPage: true })
  await page.getByLabel('Search accounts').fill('Jordan')
  await page.getByRole('button', { name: 'Search', exact: true }).click()
  await expect(page.getByText('1 accounts · Page 1')).toBeVisible()
  await expect(page.getByLabel('Role for Alex')).toHaveCount(0)
  expect(context.errors).toEqual([])
})

test('ordinary users cannot load account administration', async ({ page }) => {
  const context = await fixture(page, 0)
  let adminRequests = 0
  await page.route('**/api/v1/admin/users**', route => { adminRequests++; return route.fulfill({ status: 403, json: { code: 403, message: 'Forbidden' } }) })
  await page.goto('/admin/users')
  await expect(page.getByRole('heading', { name: 'Administrator access required' })).toBeVisible()
  await expect(page.getByRole('link', { name: 'Access', exact: true })).toHaveCount(0)
  expect(adminRequests).toBe(0)
  expect(context.errors).toEqual([])
})

test('failed updates stay editable on a small screen', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  const context = await adminFixture(page)
  await page.route('**/api/v1/admin/users/ui-member/access', route => route.fulfill({ status: 403, json: { code: 403, message: 'Administrator access required' } }))
  await page.goto('/admin/users')
  await page.getByLabel('Role for Jordan').selectOption('admin')
  await page.getByRole('button', { name: 'Save access for Jordan' }).click()
  await expect(page.getByRole('alert').filter({ hasText: 'Administrator access required' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Save access for Jordan' })).toBeEnabled()
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
  await page.screenshot({ path: '../run/mqtts-permissions/access-mobile.png', fullPage: true })
  expect(context.errors).toEqual([])
})
