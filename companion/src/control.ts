import type { ToolKit } from './agent.ts'

// Things on the Mac that Jarvis can switch for the user during an answer. The app does the switching (the mic is
// the app's), so each tool just tells it.

export type Control = 'startNotes' | 'stopNotes'

export const NOTES_GUIDE = `To take notes of a meeting, a call or anything said near the Mac, use start_note_taking: the Mac's mic then
writes down what is said until stopped, then saves it as meeting notes (stop_note_taking, or the user says "stop taking notes").
Never say you cannot listen to a meeting.`

/** Words in the user's own message that ask for notes. Only then can Jarvis switch the mic on: text in a page or an
 * email it reads can never start a recording. Stopping is always allowed. */
const ASKS_FOR_NOTES = /\b((take|taking|start|begin)\s+(the\s+|some\s+)?notes|note[- ]?tak(er|ing)|transcrib(e|ing))\b/i

export function controlTools(control: (action: Control) => void, question = ''): ToolKit {
  const start = { name: 'start_note_taking', description: "Start taking notes: the Mac's mic writes down what is said nearby (a meeting, a call) and saves it to memory until stopped.",
    input_schema: { type: 'object', properties: {} } }
  return {
    definitions: [
      ...(ASKS_FOR_NOTES.test(question) ? [start] : []),
      { name: 'stop_note_taking', description: 'Stop taking notes and save them.', input_schema: { type: 'object', properties: {} } },
    ],
    run: async (name) => {
      if (name === 'start_note_taking') {
        if (!ASKS_FOR_NOTES.test(question)) throw new Error('only the user can ask for note taking')
        control('startNotes')
        return 'Note-taking starts as soon as you finish speaking. Tell the user in a few words.'
      }
      control('stopNotes')
      return 'Note-taking stopped; the notes are being saved.'
    },
  }
}
