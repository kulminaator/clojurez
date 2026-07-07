Memory model implementation guidelines.


# Memory model ruleset for a Clojure-like runtime in Zig

> This ruleset describes **logic and invariants**, not concrete types or function names.

---

## 1. Global design goals

- **GC-only heap:**  
  **All runtime data lives in GC-managed heap space**, including:
  - Virtual stack frames
  - Environments / locals
  - Persistent data structures
  - Closures and function metadata

- **Virtual stack:**  
  The **Zig machine stack must not grow with Clojure stack depth**. All “stack frames” are heap objects linked together:
  - Recursion depth of \(10\,000\) must be safe and bounded by heap usage.
  - Stack operations are pointer manipulations, not native stack pushes.

- **Immutable semantics:**  
  Values visible to child frames or other threads are **logically immutable**:
  - Any “update” creates a new heap object.
  - Parent-visible bindings are never mutated in place.

- **Thread-safe, multi-threaded:**  
  Multiple threads share:
  - Read-only function definitions
  - Shared immutable data structures
  - GC-managed heap

---

## 2. Roots and GC protection

### 2.1 Root categories

- **Permanent roots (never collected):**
  - **Registered namespaces** (their symbol tables, var metadata, etc.).
  - **Function source definitions** (AST, bytecode, metadata, etc.).
  - **Global constants** (e.g. core library, built-in types).

- **Dynamic roots (lifetime-bound):**
  - **Thread entry points**: the initial frame/environment for each thread.
  - **Active virtual stack frames** for each thread.
  - **Thread-local root sets** (e.g. temporary values, in-flight closures).

### 2.2 Root invariants

- **Permanent root rule:**  
  Objects classified as permanent roots **must never be swept**. GC must treat them as always reachable.

- **Thread root rule:**  
  For each thread:
  - On thread start: register its entry frame/environment as a root.
  - On thread end: unregister the thread root; all data reachable only from that root becomes collectible.

- **Frame root rule:**  
  Every active virtual stack frame is part of the root graph:
  - The **current frame** of each thread is a root.
  - All frames reachable via `parent` links from the current frame are roots.
  - When a frame is logically popped, it is removed from the root graph.

---

## 3. Virtual stack frame model

### 3.1 Frame structure

Each **virtual stack frame** is a heap object with:

- **Parent pointer:** reference to the parent frame (or `null` for thread entry).
- **Environment overlay:** a mapping from local binding identifiers to heap values.
- **Metadata:** function reference, instruction pointer / continuation info, etc.

### 3.2 Lightweight frame invariant

- **No full copies:**  
  A child frame **must not copy** the parent’s environment. It only stores:
  - New bindings introduced by the function.
  - Overrides of existing bindings (shadowing).
  - Therefor - child frame must know who it's parent is.
  - There must be a tracking method for the env to see "this parent frame has these children", exited childrens must be removed from the table or list.
  - GC must take this into consideration - if any children or their children etc. are still alive along those relationship paths, 
    we can not clean up their values just yet. This rules also applies vice versa in some cases. If a child frame, e.g. in another thread now, is still
    seeing some values from the parent frame then GC can not clean up that value even if the the parent frames own execution thread can not see that value 
    anymore.
  - Blatant copying or cloning values from the parent frame is illegal and must be considered banned. This would lead to massive memory usage that we can not do.

- **Lookup rule:**
  1. On read of a binding `b`:
     - Check current frame’s overlay.
     - If not found, walk parent chain until found or root.
     - Memoize the looked up reference 
       (so that if we do a tight loop in a stack level of 25 we remember recently refered values or functions 
        and do not traverse the stack 25 times upon every usage of a function or value from parent levels, 
        nb! gc must also know that we can see the reference here, do not forget)
  2. This guarantees:
     - Minimal per-frame memory.
     - Efficient shadowing without copying.

- **Write rule (immutability):**
  - Writes **never mutate parent overlays**.
  - A “write” in a frame:
    - Allocates a new heap value.
    - Stores it in the current frame’s overlay.
  - Parent frames remain logically immutable from the child’s perspective.

### 3.3 Frame lifecycle

- **Push (call / recursion):**
  - Allocate a new frame object in heap.
  - Set its parent to the current frame.
  - Set current frame pointer to the new frame.
  - Register the new frame as part of the root graph.

- **Pop (return):**
  - Set current frame pointer to its parent.
  - Mark the popped frame as no longer active:
    - Remove from root graph.
    - It becomes collectible if no other references exist.

- **Tail calls (optional optimization):**
  - Tail call may reuse the current frame:
    - Replace function metadata and overlay.
    - Parent pointer remains unchanged.
  - Must preserve immutability invariants (no parent mutation).

---

## 4. Immutability and visibility rules

### 4.1 Binding immutability

- **Parent immutability rule:**
  - Once a frame has a child, **bindings in the parent frame that are visible to the child must never change**.
  - Any attempt to mutate such a binding is a **runtime error** or must be rewritten as:
    - Create a new value.
    - Store it in the child frame overlay.

- **Shared data immutability:**
  - Persistent data structures are immutable:
    - Updates create new nodes, sharing unchanged structure.
  - Threads may freely share references to these structures without synchronization for reads.

### 4.2 Function definition immutability

- **Function source rule:**
  - Function definitions (source, AST, bytecode, metadata) are:
    - Allocated in protected heap regions.
    - Marked read-only at the logical level.
  - No runtime operation may mutate function source objects.

- **Sharing rule:**
  - All threads may hold references to function definitions.
  - GC must treat these as permanent roots via namespace registration.

---

## 5. GC model and invariants

### 5.1 GC type

- **Non-moving mark-and-sweep GC:**
  - Objects never move; pointers remain stable.
  - GC phases:
    1. Mark: traverse from roots, mark reachable objects.
    2. Sweep: reclaim unmarked objects.

### 5.2 Root traversal

GC must treat the following as roots:

- **Permanent roots:**
  - Namespace registry.
  - Function definition registry.
  - Global constants.

- **Per-thread roots:**
  - Thread entry frame (if thread is alive).
  - Current frame of each thread.
  - All frames reachable via parent pointers from current frame.
  - Any additional thread-local root sets (e.g. temporary GC handles).

### 5.3 Frame and environment marking

- **Frame marking rule:**
  - When marking a frame:
    - Mark its environment overlay (all bound values).
    - Mark its parent frame pointer.
    - Mark its function reference and metadata.

- **Environment marking rule:**
  - For each binding value in overlay:
    - Mark the referenced heap object.
    - Recursively mark any objects reachable from that value.

### 5.4 Thread termination and GC

- **Thread termination rule:**
  - On thread exit:
    - Remove thread entry frame from root set.
    - Remove all thread-local roots.
  - After this:
    - Any object reachable only from that thread’s frames becomes collectible.

---

## 6. Concurrency and thread safety

### 6.1 Shared read-only data

- **Shared function definitions:**
  - Function definitions are read-only and shared:
    - No locks required for reading.
    - GC must ensure they are always marked via permanent roots.

- **Shared persistent structures:**
  - Immutable persistent data structures can be shared across threads:
    - Reads are lock-free.
    - Writes create new structures; sharing is via references.

### 6.2 Heap allocation and GC synchronization

- **Allocation rule:**
  - All allocations go into the GC heap.
  - No per-thread arenas or non-GC regions.

- **GC safety points (optional):**
  - Threads may periodically reach GC-safe points where:
    - Current frame and temporary roots are consistent.
    - GC may run mark-and-sweep.

- **Write barrier (if concurrent GC):**
  - If GC is concurrent, any pointer write to heap objects must:
    - Ensure the target object is marked or
    - Record the source object in a remembered set.
  - This guarantees reachability is correctly tracked during marking.

---

## 7. Non-leak and correctness guarantees

### 7.1 No leaks from frames

- **Frame leak rule:**
  - A frame must not remain referenced after it is logically popped, except:
    - If explicitly captured (e.g. for debugging or continuation).
  - Captured frames must be treated as normal heap objects:
    - If reachable from roots, they stay alive.
    - If not, they are collectible.

### 7.2 No leaks from threads

- **Thread leak rule:**
  - After thread termination:
    - No references to its frames or thread-local data may remain in global roots.
  - Any such references must be explicit and intentional (e.g. results stored in global vars).

### 7.3 Hard error conditions

- **Illegal mutation:**
  - Mutating a parent-visible binding after a child frame exists is **non-conforming**:
    - Must be detected and rejected (assertion or runtime error).

- **Illegal function source mutation:**
  - Any attempt to mutate function source objects is **undefined behavior**:
    - Must be prevented by design (no API to do so).

---

## 8. Performance and recursion considerations

### 8.1 Frame size constraints

- **Frame size rule:**
  - A frame must contain only:
    - Parent pointer.
    - Small overlay map (bindings).
    - Minimal metadata (function ref, IP/continuation).
  - No large copies of environments or data.

### 8.2 Recursion safety

- **Recursion rule:**
  - Deep recursion (e.g. \(10\,000\) frames) must:
    - Allocate frames in heap.
    - Avoid native stack growth.
    - Keep per-frame overhead small enough to be practical.

- **Tail recursion optimization (optional):**
  - Tail calls may reuse frames to reduce heap usage.
  - Must preserve all immutability and GC invariants.

---

## 9. Implementation guidance for LLM-generated code

- **Do:**
  - Implement all stack frames as heap objects.
  - Maintain a per-thread “current frame” pointer.
  - Use parent pointers for frame chains.
  - Treat namespaces and function definitions as permanent GC roots.
  - Enforce immutability by design (no parent mutation APIs).

- **Do not:**
  - Use native stack depth to represent Clojure stack.
  - Use arenas or non-GC-managed regions.
  - Move heap objects (no compacting GC).
  - Mutate function source or namespace definitions at runtime.

- **Checkpoints:**
  - Before running GC, ensure:
    - All current frames and thread roots are registered.
    - No dangling references to popped frames exist.
  - After GC, verify:
    - Permanent roots are intact.
    - No active frame or thread root was swept.

This ruleset should be treated as **non-negotiable invariants** when generating the runtime code.
