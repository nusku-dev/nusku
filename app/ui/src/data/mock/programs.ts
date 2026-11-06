// Fake programs for the sample data: call trees that look like real ones, with shared libraries,
// kernel frames, an address that could not be named and stacks the unwinder could not finish.
// Each becomes a list of stacks, and every report window samples them with some noise.

import type { Frame } from '@/lib/profile/types'

interface Node {
  fn: string | null
  /** Inherited by children that do not set their own. */
  module?: string
  file?: string
  line?: number
  kernel?: boolean
  /** Relative share of samples where this is the innermost frame. */
  self?: number
  /** 0 to 1: how much the self share swings over time, so the live view moves. */
  swing?: number
  /** True: the unwinder stops here, as for code without frame pointers or unwind tables. */
  cut?: boolean
  kids?: Node[]
}

export interface StackTemplate {
  /** Innermost first, as the server sends them. */
  frames: Frame[]
  weight: number
  swing: number
  /** Phase of the swing, so not everything rises and falls together. */
  phase: number
  complete: boolean
}

export interface Program {
  name: string
  module: string
  /** Busy CPUs, on average: 1.0 is one core flat out. */
  load: number
  stacks: StackTemplate[]
}

const libc = '/usr/lib/x86_64-linux-gnu/libc.so.6'

/** A system call: the libc wrapper, then the kernel's path down to `inner`. */
function syscall(wrapper: string, entry: string, inner: Node[]): Node {
  return {
    fn: wrapper,
    module: libc,
    kids: [
      {
        fn: 'entry_SYSCALL_64_after_hwframe',
        kernel: true,
        kids: [{ fn: 'do_syscall_64', kernel: true, kids: [{ fn: entry, kernel: true, kids: inner }] }],
      },
    ],
  }
}

function hash(text: string): number {
  let h = 2166136261
  for (let i = 0; i < text.length; i++) h = Math.imul(h ^ text.charCodeAt(i), 16777619)
  return h >>> 0
}

function address(node: Node, module: string | undefined): string {
  const h = hash(`${module}:${node.fn ?? node.line}`)
  if (node.kernel) return `ffffffff8${(0x1000000 + (h % 0xeffffff)).toString(16)}`
  const base = module === undefined || module.includes('/lib') ? 0x7f3a_0000_0000 : 0x5555_5555_0000
  return (base + (h % 0x3fffff)).toString(16)
}

function compile(name: string, module: string, load: number, root: Node): Program {
  const stacks: StackTemplate[] = []
  const walk = (node: Node, inherited: string, outer: Frame[], cut: boolean) => {
    const mod = node.kernel ? null : (node.module ?? inherited)
    const frame: Frame = {
      address: address(node, mod ?? undefined),
      kernel: node.kernel ?? false,
      function: node.fn,
      file: node.file ?? null,
      line: node.line ?? null,
      module: mod,
    }
    // A cut drops the frames outside it: the stack ends early.
    const path = node.cut ? [frame] : [frame, ...outer]
    const isCut = cut || (node.cut ?? false)
    if (node.self) {
      stacks.push({
        frames: path,
        weight: node.self,
        swing: node.swing ?? 0.15,
        phase: (hash(node.fn ?? '') % 628) / 100,
        complete: !isCut,
      })
    }
    for (const kid of node.kids ?? []) walk(kid, mod ?? inherited, path, isCut)
  }
  walk(root, module, [], false)
  return { name, module, load, stacks }
}

const orbit = '/usr/local/bin/orbit-server'
const zstd = '/usr/lib/x86_64-linux-gnu/libzstd.so.1'

const orbitServer = compile('orbit-server', orbit, 1.35, {
  fn: 'main',
  file: 'src/main.cpp',
  line: 58,
  kids: [
    {
      fn: 'orbit::Server::run()',
      file: 'src/server.cpp',
      line: 121,
      self: 1,
      kids: [
        {
          fn: 'orbit::World::tick(double)',
          file: 'src/world.cpp',
          line: 88,
          self: 2,
          kids: [
            {
              fn: 'orbit::physics::step(World&, double)',
              file: 'src/physics/step.cpp',
              line: 210,
              self: 3,
              kids: [
                {
                  fn: 'orbit::physics::Broadphase::collide()',
                  file: 'src/physics/broadphase.cpp',
                  line: 64,
                  self: 6,
                  swing: 0.5,
                  kids: [
                    { fn: 'orbit::aabb_overlap(Aabb const&, Aabb const&)', file: 'src/physics/geometry.hpp', line: 31, self: 26, swing: 0.45 },
                    { fn: 'orbit::SpatialHash::query(Aabb const&)', file: 'src/physics/spatial_hash.cpp', line: 97, self: 9 },
                  ],
                },
                {
                  fn: 'orbit::physics::Solver::integrate(double)',
                  file: 'src/physics/solver.cpp',
                  line: 142,
                  self: 10,
                  kids: [{ fn: 'orbit::Vec3::normalize()', file: 'src/math/vec3.hpp', line: 77, self: 4 }],
                },
              ],
            },
            {
              fn: 'orbit::ai::update(World&)',
              file: 'src/ai/update.cpp',
              line: 77,
              self: 2,
              kids: [
                {
                  fn: 'orbit::NavMesh::find_path(Vec3, Vec3)',
                  file: 'src/ai/navmesh.cpp',
                  line: 305,
                  self: 7,
                  swing: 0.6,
                  kids: [
                    { fn: 'orbit::BinaryHeap<Node>::push(Node)', file: 'src/util/heap.hpp', line: 44, self: 5 },
                    { fn: 'malloc', module: libc, self: 2, kids: [{ fn: '_int_malloc', self: 3 }] },
                    { fn: 'free', module: libc, self: 1, kids: [{ fn: '_int_free', self: 2 }] },
                  ],
                },
              ],
            },
            {
              fn: 'orbit::World::apply_events()',
              file: 'src/world.cpp',
              line: 164,
              self: 2,
              kids: [{ fn: 'std::_Hashtable<...>::find(EntityId const&)', file: '/usr/include/c++/13/bits/hashtable.h', line: 1702, self: 4 }],
            },
          ],
        },
        {
          fn: 'orbit::net::Session::flush()',
          file: 'src/net/session.cpp',
          line: 190,
          self: 1,
          kids: [
            {
              fn: 'orbit::Snapshot::encode(World const&)',
              file: 'src/net/snapshot.cpp',
              line: 52,
              self: 4,
              kids: [
                { fn: 'ZSTD_compressStream2', module: zstd, self: 6, kids: [{ fn: null, self: 3 }] },
              ],
            },
            syscall('send', '__x64_sys_sendto', [
              {
                fn: '__sys_sendto',
                kernel: true,
                kids: [{ fn: 'tcp_sendmsg', kernel: true, self: 2, kids: [{ fn: 'tcp_write_xmit', kernel: true, self: 2 }] }],
              },
            ]),
          ],
        },
        {
          fn: 'orbit::net::Poller::wait(int)',
          file: 'src/net/poller.cpp',
          line: 38,
          kids: [syscall('epoll_wait', '__x64_sys_epoll_wait', [{ fn: 'do_epoll_wait', kernel: true, self: 2 }])],
        },
      ],
    },
    {
      fn: 'orbit::log::Writer::thread()',
      file: 'src/log/writer.cpp',
      line: 22,
      kids: [
        { fn: 'orbit::log::format(Record const&)', file: 'src/log/format.cpp', line: 71, self: 2 },
        syscall('write', '__x64_sys_write', [
          { fn: 'ksys_write', kernel: true, kids: [{ fn: 'ext4_file_write_iter', kernel: true, self: 1 }] },
        ]),
      ],
    },
  ],
})

const pg = '/usr/lib/postgresql/16/bin/postgres'

const postgres = compile('postgres', pg, 0.9, {
  fn: 'main',
  file: 'main/main.c',
  line: 199,
  kids: [
    {
      fn: 'PostmasterMain',
      file: 'postmaster/postmaster.c',
      line: 1374,
      kids: [
        {
          fn: 'ServerLoop',
          kids: [
            {
              fn: 'BackendStartup',
              kids: [
                {
                  fn: 'PostgresMain',
                  file: 'tcop/postgres.c',
                  line: 4767,
                  kids: [
                    {
                      fn: 'exec_simple_query',
                      file: 'tcop/postgres.c',
                      line: 1278,
                      self: 1,
                      kids: [
                        { fn: 'pg_parse_query', self: 2, kids: [{ fn: 'base_yyparse', self: 4 }] },
                        { fn: 'pg_plan_queries', self: 1, kids: [{ fn: 'standard_planner', self: 3, kids: [{ fn: 'set_base_rel_sizes', self: 2 }] }] },
                        {
                          fn: 'PortalRun',
                          kids: [
                            {
                              fn: 'standard_ExecutorRun',
                              file: 'executor/execMain.c',
                              line: 365,
                              kids: [
                                {
                                  fn: 'ExecHashJoin',
                                  file: 'executor/nodeHashjoin.c',
                                  line: 218,
                                  self: 3,
                                  swing: 0.5,
                                  kids: [
                                    { fn: 'ExecScanHashBucket', self: 11, swing: 0.5 },
                                    { fn: 'hash_bytes', file: 'common/hashfn.c', line: 146, self: 5 },
                                  ],
                                },
                                {
                                  fn: 'ExecSeqScan',
                                  self: 2,
                                  kids: [
                                    { fn: 'heap_getnextslot', file: 'access/heap/heapam.c', line: 1092, self: 14 },
                                    { fn: 'ExecInterpExpr', file: 'executor/execExprInterp.c', line: 463, self: 16, kids: [{ fn: 'texteq', self: 5 }] },
                                  ],
                                },
                                {
                                  fn: 'ExecSort',
                                  kids: [{ fn: 'tuplesort_performsort', self: 3, kids: [{ fn: 'qsort_tuple', self: 7 }] }],
                                },
                              ],
                            },
                          ],
                        },
                        {
                          fn: 'pq_flush',
                          kids: [
                            syscall('__send', '__x64_sys_sendto', [{ fn: 'unix_stream_sendmsg', kernel: true, self: 2 }]),
                          ],
                        },
                      ],
                    },
                    {
                      fn: 'pq_getbyte',
                      kids: [syscall('recv', '__x64_sys_recvfrom', [{ fn: 'unix_stream_recvmsg', kernel: true, self: 1 }])],
                    },
                  ],
                },
              ],
            },
          ],
        },
      ],
    },
  ],
})

const libpython = '/usr/lib/x86_64-linux-gnu/libpython3.12.so.1.0'

const python = compile('python3', libpython, 0.95, {
  fn: 'main',
  module: '/usr/bin/python3.12',
  kids: [
    {
      fn: 'Py_RunMain',
      module: libpython,
      kids: [
        {
          fn: '_PyEval_EvalFrameDefault',
          file: 'Python/ceval.c',
          line: 1012,
          self: 22,
          swing: 0.3,
          kids: [
            { fn: 'PyObject_Malloc', file: 'Objects/obmalloc.c', line: 1617, self: 6 },
            { fn: 'dict_subscript', self: 5 },
            { fn: 'list_append', self: 3 },
            { fn: 'unicode_hash', self: 4 },
            { fn: '_PyObject_GC_Link', self: 1, kids: [{ fn: 'gc_collect_main', file: 'Modules/gcmodule.c', line: 1208, self: 5, swing: 0.9 }] },
            {
              fn: 'cfunction_call',
              kids: [
                { fn: '_json_encode_unicode', module: '/usr/lib/python3.12/lib-dynload/_json.so', self: 6 },
                { fn: null, module: '/usr/lib/python3/dist-packages/numpy/core/_multiarray_umath.so', self: 8, cut: true },
              ],
            },
            syscall('read', '__x64_sys_read', [{ fn: 'ksys_read', kernel: true, kids: [{ fn: 'filemap_read', kernel: true, self: 2 }] }]),
          ],
        },
      ],
    },
  ],
})

function generic(name: string): Program {
  const module = `/usr/bin/${name}`
  return compile(name, module, 0.4, {
    fn: 'main',
    kids: [
      {
        fn: 'event_loop_run',
        self: 1,
        kids: [
          { fn: 'handle_event', self: 3, kids: [{ fn: 'parse_message', self: 7 }, { fn: 'update_state', self: 5 }] },
          { fn: 'render', self: 2, kids: [{ fn: 'layout_text', self: 6 }, { fn: 'memcpy', module: libc, self: 3 }] },
          syscall('poll', '__x64_sys_poll', [{ fn: 'do_sys_poll', kernel: true, self: 2 }]),
        ],
      },
    ],
  })
}

const known = new Map<string, Program>([
  ['orbit-server', orbitServer],
  ['postgres', postgres],
  ['python3', python],
])

/** The fake program behind a process name. */
export function programFor(name: string): Program {
  return known.get(name) ?? generic(name)
}
