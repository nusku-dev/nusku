import { useState } from "react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";

const labelMax = 120;
const noteMax = 2000;

export interface RunLabelDialogProps {
  open: boolean;
  title: string;
  description: string;
  action: string;
  label: string;
  note: string;
  onSubmit: (label: string, note: string) => Promise<void>;
  onClose: () => void;
}

export function RunLabelDialog(props: RunLabelDialogProps) {
  return (
    <Dialog open={props.open} onOpenChange={(open) => !open && props.onClose()}>
      <DialogContent className="gap-5 sm:max-w-lg">
        {props.open && <LabelForm {...props} />}
      </DialogContent>
    </Dialog>
  );
}

function LabelForm({
  title,
  description,
  action,
  label: initialLabel,
  note: initialNote,
  onSubmit,
  onClose,
}: RunLabelDialogProps) {
  const [label, setLabel] = useState(initialLabel);
  const [note, setNote] = useState(initialNote);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const ready =
    label.trim() !== "" && label.length <= labelMax && note.length <= noteMax;

  const submit = () => {
    setBusy(true);
    setError(null);
    onSubmit(label.trim(), note.trim())
      .then(onClose)
      .catch((e: unknown) => {
        setError(e instanceof Error ? e.message : String(e));
        setBusy(false);
      });
  };

  return (
    <form
      className="grid gap-5"
      onSubmit={(e) => {
        e.preventDefault();
        if (ready && !busy) submit();
      }}
    >
      <DialogHeader>
        <DialogTitle>{title}</DialogTitle>
        <DialogDescription>{description}</DialogDescription>
      </DialogHeader>
      <div className="grid gap-1.5">
        <Label htmlFor="run-label">Label</Label>
        <Input
          id="run-label"
          autoFocus
          maxLength={labelMax}
          placeholder="init v1: sort then dedupe"
          value={label}
          onChange={(e) => setLabel(e.target.value)}
        />
      </div>
      <div className="grid gap-1.5">
        <Label htmlFor="run-note">Note</Label>
        <Textarea
          id="run-note"
          maxLength={noteMax}
          placeholder="What changed in this version, how it was run, what to compare it with"
          value={note}
          onChange={(e) => setNote(e.target.value)}
        />
      </div>
      {error && <p className="text-sm text-destructive">{error}</p>}
      <DialogFooter>
        <Button type="button" variant="outline" onClick={onClose}>
          Cancel
        </Button>
        <Button type="submit" disabled={!ready || busy}>
          {busy ? "Saving…" : action}
        </Button>
      </DialogFooter>
    </form>
  );
}
