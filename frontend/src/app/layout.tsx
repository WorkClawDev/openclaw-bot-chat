import type { Metadata } from 'next'
import { Inter, Roboto, Open_Sans, Playfair_Display, Fira_Code } from 'next/font/google'
import './globals.css'
import './agent-chat.css'
import './syntax-highlight.css'
import { AuthProvider } from '@/contexts/AuthContext'
import { ChatProvider } from '@/contexts/ChatContext'
import { ThemeProvider } from '@/components/ThemeProvider'

const inter = Inter({ subsets: ['latin'], variable: '--font-inter' })
const roboto = Roboto({ weight: ['400', '500', '700'], subsets: ['latin'], variable: '--font-roboto' })
const openSans = Open_Sans({ subsets: ['latin'], variable: '--font-open-sans' })
const playfair = Playfair_Display({ subsets: ['latin'], variable: '--font-playfair' })
const firaCode = Fira_Code({ subsets: ['latin'], variable: '--font-fira-code' })

export const metadata: Metadata = {
  title: 'BotChat - Agent Workspace',
  description: 'Work with your agents, follow their progress, and review results in one conversation.',
}

export default function RootLayout({
  children,
}: {
  children: React.ReactNode
}) {
  return (
    <html lang="en">
      <body className={`${inter.variable} ${roboto.variable} ${openSans.variable} ${playfair.variable} ${firaCode.variable} antialiased`}>
        <AuthProvider>
          <ChatProvider>
            <ThemeProvider>
              {children}
            </ThemeProvider>
          </ChatProvider>
        </AuthProvider>
      </body>
    </html>
  )
}
