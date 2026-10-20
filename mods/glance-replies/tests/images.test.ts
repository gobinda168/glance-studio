import { expect, test } from 'claude-code/testing'
import { cellSize, imageTokens, imagesOfMessage, parseClipboard, parseSize, recentDrops } from '../hooks/images.js'

test('finds each image number once, in order', async () => {
  expect(imageTokens('[Image #2] vs [Image #3], then [Image #2] again')).toEqual([2, 3])
  expect(imageTokens('no images')).toEqual([])
})

test("pairs a message's image numbers with its image blocks", async () => {
  const content = [
    { type: 'text', text: '[Image #4] and [Image #5] differ how?' },
    { type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'AAA' } },
    { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: 'BBB' } },
  ]
  expect(imagesOfMessage(content)).toEqual([
    { n: 4, mediaType: 'image/png', data: 'AAA' },
    { n: 5, mediaType: 'image/jpeg', data: 'BBB' },
  ])
  expect(imagesOfMessage('plain text')).toEqual([])
})

test('fits a picture in its cells, shape kept', async () => {
  expect(cellSize(1000, 500, 40, 10)).toEqual({ columns: 40, rows: 10 })
  expect(cellSize(2000, 500, 40, 10)).toEqual({ columns: 40, rows: 5 })
  expect(cellSize(500, 1000, 40, 10)).toEqual({ columns: 10, rows: 10 })
  expect(cellSize(100, 100, 28, 6)).toEqual({ columns: 12, rows: 6 })
})

test('reads sips sizes and the clipboard script', async () => {
  expect(parseSize('/t/a.png\n  pixelWidth: 640\n  pixelHeight: 360\n')).toEqual({ width: 640, height: 360 })
  expect(parseSize('error')).toBe(null)
  expect(parseClipboard('png:/t/clip-1.png\n')).toEqual({ png: '/t/clip-1.png' })
  expect(parseClipboard('file:/Users/me/shot.JPG')).toEqual({ file: '/Users/me/shot.JPG' })
  expect(parseClipboard('file:/Users/me/notes.txt')).toBe(null)
  expect(parseClipboard('none')).toBe(null)
})

test('only recent drops count', async () => {
  const json = '{"at":100,"paths":["\\/a\\/b.png"]}'
  expect(recentDrops(json, 105_000, 15_000)).toEqual([{ path: '/a/b.png', at: 100 }])
  expect(recentDrops(json, 200_000, 15_000)).toEqual([])
  expect(recentDrops('not json', 0, 1)).toEqual([])
})
