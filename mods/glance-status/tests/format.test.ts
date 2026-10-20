import { expect, test } from 'claude-code/testing'
import { ago, clock, compact, fit, folderName, limitLabel, modelLabel, words } from '../hooks/format.js'

test('times', () => {
  expect(clock(42_000)).toBe('0:42')
  expect(clock(725_000)).toBe('12:05')
  expect(clock(3_723_000)).toBe('1:02:03')
  expect(words(42_000)).toBe('42s')
  expect(words(72_000)).toBe('1m 12s')
  expect(words(120_000)).toBe('2m')
  expect(words(7_500_000)).toBe('2h 5m')
  expect(ago(5_000)).toBe('just now')
  expect(ago(45_000)).toBe('45s ago')
  expect(ago(200_000)).toBe('3m ago')
  expect(ago(7_300_000)).toBe('2h ago')
})

test('token counts', () => {
  expect(compact(950)).toBe('950')
  expect(compact(1_234)).toBe('1.2k')
  expect(compact(1_000)).toBe('1k')
  expect(compact(82_000)).toBe('82k')
  expect(compact(182_400)).toBe('182k')
  expect(compact(1_200_000)).toBe('1.2M')
  expect(compact(23_000_000)).toBe('23M')
})

test('names', () => {
  expect(modelLabel('claude-opus-5-5')).toBe('Opus 5.5')
  expect(modelLabel('claude-haiku-4-5-20251001')).toBe('Haiku 4.5')
  expect(modelLabel('claude-fable-5-1')).toBe('Fable 5.1')
  expect(modelLabel('gpt-x')).toBe('gpt-x')
  expect(limitLabel('five_hour')).toBe('5h')
  expect(limitLabel('seven_day')).toBe('week')
  expect(limitLabel('spend_limit')).toBe('spend limit')
  expect(folderName('/Users/a/Code/acme/')).toBe('acme')
  expect(folderName('')).toBe('')
})

test('fit cuts text to the width, keeping a path’s end', () => {
  expect(fit('short', 10)).toBe('short')
  expect(fit('a long sentence here', 10)).toBe('a long se…')
  expect(fit('Sources/GlanceCore/TabStatusBook.swift', 20)).toBe('…TabStatusBook.swift')
  expect(fit('anything', 1)).toBe('…')
  expect(fit('anything', 0)).toBe('')
})
