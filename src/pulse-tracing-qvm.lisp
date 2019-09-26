(in-package :qvm)

(defstruct pulse-event
  instruction
  start-time
  end-time
  frame-state)

;;; TODO move this to cl-quil ast code?
(defun pulse-op-frame (instr)
  (etypecase instr
    (quil:pulse (quil:pulse-frame instr))
    (quil:capture (quil:capture-frame instr))
    (quil:raw-capture (quil:raw-capture-frame instr))))

(defun pulse-event-frame (event)
  "The frame associated with a pulse event."
  (let ((instr (pulse-event-instruction event)))
    (pulse-op-frame instr)))

(defun pulse-event-duration (pulse-event)
  "The duration of a pulse event."
  (- (pulse-event-end-time pulse-event)
     (pulse-event-start-time pulse-event)))

;;; A structure tracking the state of a specific frame.
(defstruct frame-state
  (phase 0.0d0
   :type real)
  (scale 1.0d0
   :type real)
  (frequency nil
   :type (or real null))
  ;; The sample rate in Hz for waveform generation.
  (sample-rate (error "Sample rate must be defined.")
   :type real))

(defparameter *initial-pulse-event-log-length* 100
  "The initial length of the pulse tracing QVM's event log.")

;;; This is pretty barebones, but does make some claims about what is important
;;; to track. Namely, qubit local time and frame states. We also update a log,
;;; although TODO in principle this could be more generic (e.g. provide some
;;; sort of "event consumer" callbacks).
(defclass pulse-tracing-qvm (classical-memory-mixin)
  ((local-clocks :initarg :local-clocks
                 :accessor local-clocks
                 :initform (make-hash-table :test #'quil::frame= :hash-function #'quil::frame-hash)
                 :documentation "A table mapping qubit indices to the time of their last activity.")
   (frame-states :initarg :frame-states
                 :accessor frame-states
                 :initform (make-hash-table :test #'quil::frame= :hash-function #'quil::frame-hash)
                 :documentation "A table mapping frames to their active states.")
   (pulse-event-log :initarg :log
                    :accessor pulse-event-log
                    :initform  (make-array *initial-pulse-event-log-length*
                                           :fill-pointer 0
                                           :adjustable t)
                    :documentation "A log, in chronological order, of observed pulse events."))
  (:documentation "A quantum virtual machine capable of tracing pulse sequences over time."))

;;; TODO this fakeness is mainly to make LOAD-PROGRAM happy
(defmethod number-of-qubits ((qvm pulse-tracing-qvm))
  most-positive-fixnum)

(defun make-pulse-tracing-qvm ()
  "Create a new pulse tracing QVM."
  (make-instance 'pulse-tracing-qvm
                 :classical-memory-subsystem
                 (make-instance 'classical-memory-subsystem
                                :classical-memory-model
                                quil:**empty-memory-model**)))

(defun initialize-frame-states (qvm frame-definitions)
  "Set up initial frame states on the pulse tracing QVM."
  (check-type qvm pulse-tracing-qvm)
  (dolist (defn frame-definitions)
    (let ((frame (quil:frame-definition-frame defn))
          (sample-rate (quil:frame-definition-sample-rate defn))
          (initial-frequency (quil:frame-definition-initial-frequency defn)))
      (unless sample-rate
        (error "Frame ~A has unspecified sample-rate" frame))
      (setf (gethash frame (frame-states qvm))
            (make-frame-state :frequency (and initial-frequency
                                              (quil:constant-value initial-frequency))
                              :sample-rate (quil:constant-value sample-rate))))))

(defun trace-quilt-program (program)
  "Trace a quilt PROGRAM, returning a list of pulse events."
  (check-type program quil:parsed-program)
  (let* ((qvm (make-pulse-tracing-qvm)))
    (initialize-frame-states qvm (quil:parsed-program-frame-definitions program))
    (load-program qvm program)
    (run qvm)
    (pulse-event-log qvm)))

(defun local-time (qvm frame &optional (default 0.0d0))
  "Get the local time of FRAME on the pulse tracing QVM."
  (check-type qvm pulse-tracing-qvm)
  (gethash frame (local-clocks qvm) default))

(defun (setf local-time) (new-value qvm frame)
  "Set the local time of FRAME on the pulse tracing QVM."
  (setf (gethash frame (local-clocks qvm))
        new-value))

(defun frame-state (qvm frame)
  "Returns a copy of the state associated with the given frame."
  (check-type qvm pulse-tracing-qvm)
  (alexandria:if-let ((state (gethash frame (frame-states qvm))))
    (copy-structure state)
    (error "Attempted to reference non-existent frame ~A" frame)))

(defun (setf frame-state) (new-value qvm frame)
  "Set the state associated with the given frame."
  (check-type qvm pulse-tracing-qvm)
  (if (gethash frame (frame-states qvm))
      (setf (gethash frame (frame-states qvm))
            new-value)
      (error "Attempted to modify non-existent frame ~A" frame)))

(defun latest-time (qvm &rest frames)
  "Get the latest time of the specified FRAMES on the pulse tracing QVM."
  (loop :for f :in frames :maximize (local-time qvm f)))

;;; TRANSITIONs

(defun intersecting-frames (qvm &rest qubits)
  "Return all frames tracked by the pulse tracing QVM which involve any of the specified QUBITS."
  (check-type qvm pulse-tracing-qvm)
  (loop :for frame :being :the :hash-key :of (frame-states qvm)
        :when (intersection qubits
                            (quil:frame-qubits frame)
                            :test #'equalp)
          :collect frame))

(defun frames-on-qubits (qvm &rest qubits)
  "Return all frames tracked by the pulse tracing QVM which involve exactly the specified QUBITS."
  (check-type qvm pulse-tracing-qvm)
  (loop :for frame :being :the :hash-key :of (frame-states qvm)
        :when (equalp qubits (quil:frame-qubits frame))
          :collect frame))

(defmethod transition ((qvm pulse-tracing-qvm) (instr quil:delay-on-frames))
  (dolist (frame (quil:delay-frames instr))
    (incf (local-time qvm frame) (quil:delay-duration instr)))

  (incf (pc qvm))
  qvm)

(defmethod transition ((qvm pulse-tracing-qvm) (instr quil:delay-on-qubits))
  (let* ((frames (frames-on-qubits qvm (quil:delay-qubits instr)))
         (latest (apply #'latest-time qvm frames)))
    (dolist (frame frames)
      (setf (local-time qvm frame) latest)))

  (incf (pc qvm))
  qvm)

(defmethod transition ((qvm pulse-tracing-qvm) (instr quil:fence))
  (let* ((frames (apply #'intersecting-frames qvm (quil:fence-qubits instr)))
         (latest (apply #'latest-time qvm frames)))
    (dolist (frame frames)
      (setf (local-time qvm frame) latest)))

  (incf (pc qvm))
  qvm)

(defmethod transition ((qvm pulse-tracing-qvm) (instr quil:simple-frame-mutation))
  (let* ((frame (quil:frame-mutation-target-frame instr))
         (val (quil:constant-value
               (quil:frame-mutation-value instr)))
         (fs (frame-state qvm frame)))

    ;; update state
    (etypecase instr
      (quil:set-frequency
       (setf (frame-state-frequency fs) val))
      (quil:set-phase
       (setf (frame-state-phase fs) val))
      (quil:shift-phase
       (incf (frame-state-phase fs) val))
      (quil:set-scale
       (setf (frame-state-scale fs) val)))

    ;; update entry
    (setf (frame-state qvm frame) fs))

  (incf (pc qvm))
  qvm)

(defmethod transition ((qvm pulse-tracing-qvm) (instr quil:swap-phase))
  (with-slots (left-frame right-frame) instr
    (when (equalp left-frame right-frame)
      (error "SWAP-PHASE requires distinct frames."))
    (let ((left-state (frame-state qvm left-frame))
          (right-state (frame-state qvm right-frame)))
      (rotatef (frame-state-phase left-state) (frame-state-phase right-state))
      (setf (frame-state qvm left-frame) left-state
            (frame-state qvm right-frame) right-state)))

  (incf (pc qvm))
  qvm)

;;; TODO: should we allow transition on other instructions? classical control flow?
(defmethod transition ((qvm pulse-tracing-qvm) instr)
  (unless (typep instr '(or quil:pulse quil:capture quil:raw-capture))
    (error "Cannot resolve timing information for instruction ~A" instr))
  (let* ((frame (pulse-op-frame instr))
         (frame-state (frame-state qvm frame))
         (start-time (latest-time qvm frame))
         (end-time (+ start-time
                      (quil::quilt-instruction-duration instr))))
    (vector-push-extend (make-pulse-event :instruction instr
                                          :start-time start-time
                                          :end-time end-time
                                          :frame-state frame-state)
                        (pulse-event-log qvm))
    (setf (local-time qvm frame) end-time)

    (unless (quil:nonblocking-p instr)
      ;; this pulse/capture/raw-capture excludes other frames until END-TIME
      (dolist (other (apply #'intersecting-frames qvm (quil:frame-qubits frame)))
        (quil:print-instruction other)
        (setf (local-time qvm other)
              (max end-time (local-time qvm other))))))

  (incf (pc qvm))
  qvm)
