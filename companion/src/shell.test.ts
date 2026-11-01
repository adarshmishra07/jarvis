import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, writeFileSync, existsSync, readFileSync, mkdirSync, realpathSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir, homedir } from 'node:os'
import { shellTools, looksOnly } from './shell.ts'

test('only plain look-up commands skip the question', () => {
  for (const c of ['ls -la ~/Downloads', 'mdfind -name invoice | head -5', 'pmset -g batt', 'find . -name "*.pdf"']) assert.equal(looksOnly(c), true, c)
  for (const c of ['cp a b', 'df -h && pmset -g batt', 'find . -delete', 'find . -exec rm {} \;', 'ls $(rm x)', 'ls > out.txt', 'echo `id`', 'ls | xargs rm', 'env rm x', 'ls\nrm x', 'ls & rm x', 'ls; rm x', 'ls && rm x', 'rg --pre zsh x', 'find . -okdir rm {} +']) assert.equal(looksOnly(c), false, c)
})

test('the sandbox, not the words, stops writes, network, private files and other apps', async () => {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), 'shell-')))
  const victim = join(dir, 'keep.txt'); writeFileSync(victim, 'keep me')
  const asked: string[] = []
  const kit = shellTools(async (a) => { asked.push(a); return true }, join(dir, 'work'))
  const out = (c: string): Promise<string> => kit.run('mac_command', { command: c }) as Promise<string>
  assert.match(await out(`cat ${victim}`), /keep me/)
  assert.equal(asked.length, 0, 'a look-up runs without asking')
  await out(`mv ${victim} ${victim}.moved; echo x > ${victim}`) // asks (approved here), then the kernel refuses
  assert.equal(readFileSync(victim, 'utf8'), 'keep me')
  assert.equal(existsSync(victim + '.moved'), false)
  const net = await out('ping -c 1 -t 2 1.1.1.1; dig +time=1 +tries=1 example.com; echo done')
  assert.match(net, /done/)
  assert.doesNotMatch(net, /bytes from|ANSWER SECTION/, 'no network at all')
  assert.match(await out('/usr/bin/osascript -e "1"'), /not permitted/)
  assert.match(await out('python3 -c "print(1)"'), /not permitted/)
  assert.match(await out('cp /usr/bin/osascript ./o && ./o -e "1"'), /not permitted/, 'a copy in the scratch folder cannot run either')
  const ssh = join(homedir(), '.ssh')
  if (existsSync(ssh)) assert.doesNotMatch(await out(`ls ${ssh} && echo LISTED`), /LISTED/)
  assert.match(await out('rm -rf ~/Documents'), /^Refused/, 'the never-list refuses before asking')
  assert.match(await out('echo hi > note.txt && cat note.txt'), /hi/, 'its own scratch folder is writable')
})
