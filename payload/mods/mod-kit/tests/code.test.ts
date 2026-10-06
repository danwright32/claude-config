import { describe, expect, test } from 'claude-code/testing'
import { codeVerdict } from '../hooks/code.ts'

// The per language judge of inline code (#712: moved here from scope-modes, so $.modkit.writes and
// no build read code the same way). Its rules are pinned end to end through no build's own tests;
// these are the ones #730 changed.
describe('codeVerdict after #730', () => {
  // The rule naming a builtin to send or method had no trailing boundary, so a method merely
  // starting with one was refused as running a process.
  test("ruby's send and method name a builtin only when the whole name is one", () => {
    expect(codeVerdict('ruby', 'conn.send(:execute, sql)')).toBeUndefined()
    expect(codeVerdict('ruby', 'h = method(:fork_helper)')).toBeUndefined()
    expect(codeVerdict('ruby', 'send(:spawn_worker)')).toBeUndefined()
    expect(codeVerdict('ruby', 'obj.public_send(:system?)')).toBeUndefined()
    expect(codeVerdict('ruby', '"".send(:system, "ls")')).toEqual({ does: 'run a process', seen: 'system' })
    expect(codeVerdict('ruby', 'send(:exec, "ls")')).toEqual({ does: 'run a process', seen: 'exec' })
    expect(codeVerdict('ruby', 'send("`", "ls")')).toEqual({ does: 'run a process', seen: 'backticks' })
  })
  test('a send of a name built at run time still cannot be read', () => {
    expect(codeVerdict('ruby', 'send(name, "ls")')).toEqual({ does: 'unreadable', seen: 'send of a computed name' })
    expect(codeVerdict('ruby', 'send("sys" + "tem", "ls")')).toEqual({ does: 'unreadable', seen: 'send of a computed name' })
  })
  test("python's fileinput rewrites its files in place when inplace is set", () => {
    expect(codeVerdict('python', "import fileinput\nfor l in fileinput.input('a.txt', inplace=True): print(l)")).toEqual({ does: 'write files', seen: 'fileinput with inplace' })
    expect(codeVerdict('python', "import fileinput; fileinput.FileInput(files=['a'], inplace=1)")).toEqual({ does: 'write files', seen: 'fileinput with inplace' })
    expect(codeVerdict('python', "from fileinput import input\nfor l in input('a', inplace=True): pass")).toEqual({ does: 'write files', seen: 'fileinput with inplace' })
    expect(codeVerdict('python', "import fileinput\nfor l in fileinput.input('a.txt'): print(l)")).toBeUndefined()
    expect(codeVerdict('python', "import fileinput\nfor l in fileinput.input('a.txt', inplace=False): print(l)")).toBeUndefined()
  })
  test("pathlib's rename and replace move a file; str.replace and a data frame's rename do not", () => {
    expect(codeVerdict('python', "from pathlib import Path; Path('a').rename('b')")).toEqual({ does: 'write files', seen: 'rename' })
    expect(codeVerdict('python', "from pathlib import Path; p = Path('a'); p.replace(target)")).toEqual({ does: 'write files', seen: 'replace' })
    expect(codeVerdict('python', "print('abc'.replace('a', 'b'))")).toBeUndefined()
    expect(codeVerdict('python', "s = name.replace('x', '', 1)")).toBeUndefined()
    expect(codeVerdict('python', "df = df.rename(columns={'a': 'b'})")).toBeUndefined()
    expect(codeVerdict('python', "df.replace({'a': 'b'})")).toBeUndefined()
    expect(codeVerdict('python', 'df.rename(str.lower, axis=1)')).toBeUndefined()
  })
})

// #760 items 5, decided by Dan on 2026-10-05: two false refusals stop, the real routes stay refused.
describe('codeVerdict after #760', () => {
  test("a pandas Series.rename with one name is no move; a pathlib rename still is", () => {
    expect(codeVerdict('python', "import pandas as pd\ns = pd.Series([1, 2])\ns = s.rename('total')")).toBeUndefined()
    expect(codeVerdict('python', "import pandas as pd\ndf['x'].replace('a')")).toBeUndefined()
    expect(codeVerdict('python', "from pathlib import Path\nPath('a').rename('b')")).toEqual({ does: 'write files', seen: 'rename' })
    expect(codeVerdict('python', "import pathlib\npathlib.Path('a').replace('b')")).toEqual({ does: 'write files', seen: 'replace' })
    // pandas and pathlib in one script: which receiver is which cannot be told, so it is a move.
    expect(codeVerdict('python', "import pandas as pd\nfrom pathlib import Path\np = Path('a')\np.rename('b')")).toEqual({ does: 'write files', seen: 'rename' })
    // Neither imported: the receiver is unknown, so it is still read as a move.
    expect(codeVerdict('python', "x.rename('b')")).toEqual({ does: 'write files', seen: 'rename' })
    // os.rename is its own rule and is untouched by pandas being imported.
    expect(codeVerdict('python', "import pandas as pd\nimport os\nos.rename('a', 'b')")).toEqual({ does: 'write files', seen: 'os.rename' })
  })
  test("ruby's def send(x) defines a method; a send of a computed name is still unreadable", () => {
    expect(codeVerdict('ruby', 'class Mailer\n  def send(x)\n    deliver(x)\n  end\nend')).toBeUndefined()
    expect(codeVerdict('ruby', 'def self.send(msg) = puts(msg)')).toBeUndefined()
    expect(codeVerdict('ruby', 'def public_send(name, *args); end')).toBeUndefined()
    expect(codeVerdict('ruby', 'send(name, "ls")')).toEqual({ does: 'unreadable', seen: 'send of a computed name' })
    expect(codeVerdict('ruby', 'def go(n)\n  send(n)\nend')).toEqual({ does: 'unreadable', seen: 'send of a computed name' })
  })
})
