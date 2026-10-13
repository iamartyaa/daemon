import React from 'react';
import {Composition, registerRoot} from 'remotion';
import {Filters, FILTERS_FRAMES} from './Filters';
import {KEEP_REGION_FRAMES, KeepRegion} from './KeepRegion';
import {KEEP_TEXT_FRAMES, KeepText} from './KeepText';
import {KEEP_VOICE_FRAMES, KeepVoice} from './KeepVoice';
import {Recall, RECALL_FRAMES} from './Recall';
import {ClipProps, FPS, H, W} from './ui';

// Every clip renders once per theme as `<clip>-<ivory|smoked>`.
const clips: {id: string; component: React.FC<ClipProps>; frames: number}[] = [
  {id: 'keep-text', component: KeepText, frames: KEEP_TEXT_FRAMES},
  {id: 'keep-voice', component: KeepVoice, frames: KEEP_VOICE_FRAMES},
  {id: 'keep-region', component: KeepRegion, frames: KEEP_REGION_FRAMES},
  {id: 'recall', component: Recall, frames: RECALL_FRAMES},
  {id: 'filters', component: Filters, frames: FILTERS_FRAMES},
];

const Root: React.FC = () => (
  <>
    {clips.flatMap(({id, component, frames}) =>
      (['ivory', 'smoked'] as const).map((theme) => (
        <Composition
          key={`${id}-${theme}`}
          id={`${id}-${theme}`}
          component={component}
          durationInFrames={frames}
          fps={FPS}
          width={W * 2}
          height={H * 2}
          defaultProps={{theme}}
        />
      )),
    )}
  </>
);

registerRoot(Root);
