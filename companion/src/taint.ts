// Session taint: once anything a tool brought into this conversation is sensitive (a card or phone number, an ID, a
// key or a code), every step that could carry it out (the browser, typing on the screen, skill commands) waits for the
// user's yes for the rest of the conversation. Each step on its own may look harmless; together they could be
// "read the code from the email, then put it in a page". The never-list still refuses outright first.
import type { ToolKit, ToolOutput } from './agent.ts'
import { sensitive } from './never.ts'

/** Tools that can take something out of the Mac. Connected-app writes already ask with every argument shown. */
const OUTBOUND = /^(browser_(open|click|type)|type|key|run_command|mac_command)$/
const asText = (out: ToolOutput): string => typeof out === 'string' ? out : out.map((b) => b.type === 'text' ? b.text : '').join('\n')

/** A screenshot can show anything on screen: the web and skill commands ask after one. Typing on the screen is left
 * to Jarvis Hands, which refuses numbers and addresses itself (asking before every key would make the screen unusable). */
const AFTER_IMAGE = /^(browser_(open|click|type)|run_command)$/

export function tainted(kit: ToolKit, approve: (action: string) => Promise<boolean>, already = false): ToolKit {
  let marked = already
  let sawImage = false
  return {
    ...kit,
    get definitions() { return kit.definitions },
    get maxSteps() { return kit.maxSteps },
    run: async (name, input) => {
      if ((marked && OUTBOUND.test(name)) || (sawImage && AFTER_IMAGE.test(name))) {
        const what = `${name.replace(/_/g, ' ')} ${JSON.stringify(input ?? {}).slice(0, 300)}`
        if (!(await approve(`This conversation has read private details (a number, code or key). Let Jarvis go on: ${what}?`)))
          return 'The user said no: this conversation holds private details, so nothing more leaves the Mac in it. Tell the user what is left.'
      }
      let out: ToolOutput
      try { out = await kit.run(name, input) } catch (e) {
        if (sensitive(e instanceof Error ? e.message : String(e))) marked = true // an error can quote what it read
        throw e
      }
      if (sensitive(asText(out))) marked = true
      if (typeof out !== 'string' && out.some((b) => b.type === 'image')) sawImage = true
      return out
    },
  }
}
