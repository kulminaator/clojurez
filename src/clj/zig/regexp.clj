;; zig.regexp - Regular expression engine implemented in pure Clojure
;; Uses Thompson NFA construction for pattern matching.

(ns zig.regexp)

;; ============================================================
;; Regex Parser - converts regex string to AST
;; ============================================================

(defn- parse-regex [s]
  "Parse a regex string into an AST."
  (let [result (parse-alt {:s s :pos 0 :gc 0})]
    (:ast result)))

(defn- peek-char [ctx]
  (let [pos (:pos ctx)
        s (:s ctx)]
    (when (< pos (count s))
      (nth s pos))))

(defn- consume-char [ctx]
  (assoc ctx :pos (inc (:pos ctx))))

(defn- at-end? [ctx]
  (>= (:pos ctx) (count (:s ctx))))

(defn- make-ast [type & kwargs]
  (if (empty? kwargs)
    {:type type}
    (apply assoc {:type type} kwargs)))

(defn- parse-alt [ctx]
  "Parse alternation: concat ('|' concat)*"
  (let [left (parse-concat ctx)
        left-ast (:ast left)]
    (loop [ctx left children [left-ast]]
      (if (and (not (at-end? ctx)) (= (peek-char ctx) \|))
        (let [ctx (consume-char ctx)
              right (parse-concat ctx)
              right-ast (:ast right)]
          (recur ctx (conj children right-ast)))
        (let [final-ast (if (> (count children) 1)
                          (make-ast :alt :children children)
                          (first children))]
          (assoc ctx :ast final-ast))))))

(defn- parse-concat [ctx]
  "Parse concatenation: star+"
  (loop [ctx ctx children []]
    (let [c (peek-char ctx)]
      (if (or (at-end? ctx) (= c \|) (= c \)))
        (let [final-ast (if (empty? children)
                          (make-ast :empty)
                          (if (= (count children) 1)
                            (first children)
                            (make-ast :concat :children children)))]
          (assoc ctx :ast final-ast))
        (let [star-result (parse-star ctx)
              star-ast (:ast star-result)]
          (if (= (:type star-ast) :empty)
            (let [final-ast (if (empty? children)
                              (make-ast :empty)
                              (if (= (count children) 1)
                                (first children)
                                (make-ast :concat :children children)))]
              (assoc star-result :ast final-ast))
            (recur star-result (conj children star-ast))))))))

(defn- parse-star [ctx]
  "Parse star: repeat ('*' | '+' | '?')?"
  (let [repeat-result (parse-repeat ctx)
        repeat-ast (:ast repeat-result)]
    (let [c (peek-char repeat-result)]
      (cond
        (= c \*)
        (let [ctx (consume-char repeat-result)]
          (assoc ctx :ast (make-ast :star :child repeat-ast)))
        (= c \+)
        (let [ctx (consume-char repeat-result)]
          (assoc ctx :ast (make-ast :plus :child repeat-ast)))
        (= c \?)
        (let [ctx (consume-char repeat-result)]
          (assoc ctx :ast (make-ast :quest :child repeat-ast)))
        :else
        repeat-result))))

(defn- parse-repeat [ctx]
  "Parse atom: '(' alt ')' | '[' class ']' | '.' | escaped | char"
  (let [c (peek-char ctx)]
    (cond
      (nil? c)
      (assoc ctx :ast (make-ast :empty))

      (= c \( )
      (let [ctx (consume-char ctx)
            alt-result (parse-alt ctx)
            alt-ast (:ast alt-result)]
        (if (= (peek-char alt-result) \)))
          (let [ctx (consume-char alt-result)
                gc (:gc ctx)]
            (assoc ctx :ast (make-ast :group :child alt-ast :index gc)
                   :gc (inc gc)))
          (assoc alt-result :ast (make-ast :empty))))

      (= c \[)
      (let [ctx (consume-char ctx)]
        (parse-char-class ctx))

      (= c \.)
      (let [ctx (consume-char ctx)]
        (assoc ctx :ast (make-ast :dot)))

      (= c \\)
      (let [ctx (consume-char ctx)
            ec (peek-char ctx)]
        (if ec
          (let [ctx (consume-char ctx)]
            (assoc ctx :ast (make-ast :literal :char ec)))
          (assoc ctx :ast (make-ast :empty))))

      :else
      (let [ctx (consume-char ctx)]
        (assoc ctx :ast (make-ast :literal :char c)))))

(defn- parse-char-class [ctx]
  "Parse character class: [ ('^')? char-ranges* ]"
  (let [c (peek-char ctx)
        negated (if (= c \^) true false)
        ctx (if negated (consume-char ctx) ctx)]
    (loop [ctx ctx chars #{}]
      (let [c (peek-char ctx)]
        (cond
          (nil? c)
          (assoc ctx :ast (make-ast :char-class :chars chars :negated negated))

          (= c \])
          (let [ctx (consume-char ctx)]
            (assoc ctx :ast (make-ast :char-class :chars chars :negated negated)))

          :else
          (let [ctx (consume-char ctx)
                next-c (peek-char ctx)]
            (if (and (= next-c \-)
                     (not= (peek-char (assoc ctx :pos (inc (:pos ctx)))) \]))
              ;; Character range c-d
              (let [ctx (consume-char ctx)
                    end-c (peek-char ctx)]
                (if end-c
                  (let [ctx (consume-char ctx)
                        range-chars (set (map char (range (int c) (inc (int end-c)) 1)))]
                    (recur ctx (into chars range-chars)))
                  (recur ctx (conj chars c))))
              ;; Single character
              (recur ctx (conj chars c)))))))))

;; ============================================================
;; Thompson NFA Construction
;; ============================================================

;; NFA construction helpers — use atoms for mutable state
(def tb-id-counter (atom 0))
(def tb-states (atom {}))

(defn- tb-new-id []
  (let [i @tb-id-counter]
    (swap! tb-id-counter inc)
    i))

(defn- tb-new-state []
  (let [id (tb-new-id)]
    (swap! tb-states assoc id {:trans {} :eps []})
    id))

(defn- tb-merge-states [from to]
  (let [from-s (get @tb-states from)
        to-s (get @tb-states to)]
    (swap! tb-states assoc to
           {:trans (merge (get from-s :trans {})
                          (get to-s :trans {}))
            :eps (into (get from-s :eps [])
                       (get to-s :eps []))
            :dot (or (get from-s :dot)
                     (get to-s :dot))
            :cc (or (get from-s :cc)
                    (get to-s :cc))})))

(defn- tb-build-node [node]
  (let [nt (:type node)]
    (cond
      (= nt :literal)
      (let [s (tb-new-state)
            a (tb-new-state)
            c (:char node)]
        (swap! tb-states update s update :trans assoc c a)
        [s a])

      (= nt :dot)
      (let [s (tb-new-state)
            a (tb-new-state)]
        (swap! tb-states assoc s
               (assoc (get @tb-states s) (= nt :dot) a))
        [s a])

      (= nt :concat)
      (let [children (:children node)
            pairs (vec (map tb-build-node children))
            first-start (first (first pairs))
            last-accept (second (last pairs))]
        (loop [i 0]
          (if (< i (dec (count pairs)))
            (let [ai (second (nth pairs i))
                  si (first (nth pairs (inc i)))]
              (tb-merge-states ai si)
              (recur (inc i)))
            nil))
        [first-start last-accept])

      (= nt :alt)
      (let [s (tb-new-state)
            a (tb-new-state)
            children (:children node)
            pairs (vec (map tb-build-node children))]
        (doseq [[cs _] pairs]
          (swap! tb-states update s update :eps conj cs))
        (doseq [[_ ca] pairs]
          (swap! tb-states update ca update :eps conj a))
        [s a])

      (= nt :star)
      (let [s (tb-new-state)
            a (tb-new-state)
            [cs ca] (tb-build-node (:child node))]
        (swap! tb-states update s update :eps conj cs)
        (swap! tb-states update s update :eps conj a)
        (swap! tb-states update ca update :eps conj cs)
        (swap! tb-states update ca update :eps conj a)
        [s a])

      (= nt :plus)
      (let [[cs ca] (tb-build-node (:child node))]
        (swap! tb-states update ca update :eps conj cs)
        [cs ca])

      (= nt :quest)
      (let [s (tb-new-state)
            a (tb-new-state)
            [cs ca] (tb-build-node (:child node))]
        (swap! tb-states update s update :eps conj cs)
        (swap! tb-states update s update :eps conj a)
        (swap! tb-states update ca update :eps conj a)
        [s a])

      (= nt :char-class)
      (let [s (tb-new-state)
            a (tb-new-state)
            chars (:chars node)
            negated (:negated node false)]
        (swap! tb-states assoc s
               (assoc (get @tb-states s) :cc {:chars chars :neg negated :target a}))
        [s a])

      (= nt :group)
      (tb-build-node (:child node))

      (= nt :empty)
      (let [s (tb-new-state)]
        [s s])

      true  ;; default
      (let [s (tb-new-state)]
        [s s]))))

(defn- thompson-build [ast]
  "Build NFA from AST."
  (reset! tb-id-counter 0)
  (reset! tb-states {})
  (let [[start accept] (tb-build-node ast)]
    {:start start
     :accept accept
     :states @tb-states}))
;; ============================================================
;; NFA Epsilon Closure
;; ============================================================

(defn- epsilon-closure [states current-states]
  "Compute epsilon closure of a set of state IDs."
  (loop [stack (vec current-states)
         closure #{}]
    (if (empty? stack)
      closure
      (let [state (first stack)
            rest-stack (rest stack)]
        (if (contains? closure state)
          (recur rest-stack closure)
          (let [state-data (get states state)
                eps (if state-data (get state-data :eps []) [])]
            (recur (into rest-stack eps)
                   (conj closure state))))))))

;; ============================================================
;; NFA Matching Engine
;; ============================================================

(defn- nfa-next-states [states current-states ch]
  "Given current set of states and input char, return next set of states."
  (loop [result #{}
         remaining (vec current-states)]
    (if (empty? remaining)
      result
      (let [state-id (first remaining)
            state-data (get states state-id)]
        (if (nil? state-data)
          (recur result (rest remaining))
          (let [trans (get state-data :trans {})
                dot-target (get state-data :dot)
                cc (get state-data :cc)
                result (if (contains? trans ch)
                         (conj result (get trans ch))
                         result)
                result (if dot-target
                         (conj result dot-target)
                         result)
                result (if cc
                         (let [chars (get cc :chars #{})
                               neg (get cc :neg false)
                               in-class (contains? chars ch)
                               matches (if neg (not in-class) in-class)]
                           (if matches
                             (conj result (get cc :target))
                             result))
                         result)]
            (recur result (rest remaining))))))))

(defn- nfa-match [nfa s]
  "Try to match the NFA against string s (anchored at start).
   Returns true if accept state is reachable after consuming all input."
  (let [start-state (:start nfa)
        accept-state (:accept nfa)
        nfa-states (:states nfa)
        chars (vec (seq s))]
    (loop [current-states (epsilon-closure nfa-states #{start-state})
           remaining chars]
      (if (empty? remaining)
        (contains? current-states accept-state)
        (let [ch (first remaining)
              next-states (nfa-next-states nfa-states current-states ch)
              next-closure (epsilon-closure nfa-states next-states)]
          (if (empty? next-closure)
            false
            (recur next-closure (rest remaining))))))))

(defn- nfa-match-len [nfa s]
  "Find the longest match length of NFA against string s."
  (let [n (count s)]
    (loop [length 0 best 0]
      (if (>= length n)
        best
        (let [substring (apply str (take length s))]
          (if (nfa-match nfa substring)
            (recur (inc length) length)
            best))))))

;; ============================================================
;; Public API
;; ============================================================

(defn re-pattern
  "Compile a regex pattern string into a pattern object."
  [s]
  (let [ast (parse-regex s)
        nfa (thompson-build ast)]
    {:pattern s :ast ast :nfa nfa}))

(defn- get-nfa [pattern]
  "Extract or compile NFA from a pattern (string or pattern object)."
  (if (map? pattern)
    (get pattern :nfa)
    (thompson-build (parse-regex pattern))))

(defn re-matches
  "If string matches the entire regex pattern, return the match string, else nil."
  [pattern s]
  (if (nfa-match (get-nfa pattern) s)
    s
    nil))

(defn re-find
  "Find the first match of pattern in string.
   Returns the match string if found, nil otherwise."
  [pattern s]
  (let [nfa (get-nfa pattern)]
    (loop [start 0]
      (if (> start (count s))
        nil
        (let [remaining-chars (drop start (seq s))
              remaining-str (apply str remaining-chars)]
          (if (nfa-match nfa remaining-str)
            (let [match-len (nfa-match-len nfa remaining-chars)]
              (if (zero? match-len)
                (recur (inc start))
                (apply str (take match-len remaining-chars))))
            (recur (inc start))))))))

(defn re-seq
  "Return a sequence of successive non-overlapping matches of pattern in string."
  [pattern s]
  (let [nfa (get-nfa pattern)]
    (loop [start 0
           matches []]
      (if (> start (count s))
        (vec (reverse matches))
        (let [remaining-chars (drop start (seq s))
              remaining-str (apply str remaining-chars)]
          (if (nfa-match nfa remaining-str)
            (let [match-len (nfa-match-len nfa remaining-chars)]
              (if (zero? match-len)
                (recur (inc start) (conj matches ""))
                (let [match-str (apply str (take match-len remaining-chars))]
                  (recur (+ start match-len) (conj matches match-str)))))
            (recur (inc start) matches)))))))

(defn re-split
  "Split string by regex pattern. Returns a vector of substrings."
  [pattern s]
  (let [nfa (get-nfa pattern)
        all-chars (vec (seq s))
        n (count s)]
    (loop [start 0
           parts []]
      (let [remaining-chars (subvec all-chars start)
            remaining-str (apply str remaining-chars)]
        (if (nfa-match nfa remaining-str)
          (let [match-len (nfa-match-len nfa remaining-chars)]
            (if (zero? match-len)
              (recur (inc start) (conj parts (str (nth all-chars start))))
              (let [before (apply str (subvec all-chars start (- (+ start match-len) start) 0))]
                ;; Actually just collect the before part
                (let [before-str (apply str (subvec all-chars start))]
                  (recur (+ start match-len) (conj parts before-str))))))
          (let [final-part (apply str remaining-chars)]
            (vec (conj parts final-part))))))))

(defn re-replace
  "Replace first match of pattern in string with replacement.
   replacement can be a string or a function of the match string."
  [pattern s replacement]
  (let [nfa (get-nfa pattern)
        all-chars (vec (seq s))]
    (loop [start 0]
      (if (> start (count all-chars))
        s
        (let [remaining-chars (subvec all-chars start)
              remaining-str (apply str remaining-chars)]
          (if (nfa-match nfa remaining-str)
            (let [match-len (nfa-match-len nfa remaining-chars)]
              (if (zero? match-len)
                (recur (inc start))
                (let [before (apply str (subvec all-chars 0 start))
                      after (apply str (subvec all-chars (+ start match-len)))
                      match-str (apply str (subvec all-chars start (+ start match-len)))
                      repl-str (if (fn? replacement)
                                 (replacement match-str)
                                 replacement)]
                  (str before repl-str after))))
            s))))))

(defn re-replace-all
  "Replace all matches of pattern in string with replacement."
  [pattern s replacement]
  (let [nfa (get-nfa pattern)
        all-chars (vec (seq s))]
    (loop [start 0
           parts []]
      (if (> start (count all-chars))
        (let [remaining (apply str (subvec all-chars start))]
          (apply str (conj parts remaining)))
        (let [remaining-chars (subvec all-chars start)
              remaining-str (apply str remaining-chars)]
          (if (nfa-match nfa remaining-str)
            (let [match-len (nfa-match-len nfa remaining-chars)]
              (if (zero? match-len)
                (recur (inc start) (conj parts (str (nth all-chars start))))
                (let [match-str (apply str (subvec all-chars start (+ start match-len)))
                      repl-str (if (fn? replacement)
                                 (replacement match-str)
                                 replacement)]
                  (recur (+ start match-len) (conj parts repl-str)))))
            (recur (inc start) (conj parts (str (nth all-chars start))))))))))
