import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { Landing } from './pages/Landing';

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <Landing />
  </StrictMode>
);
